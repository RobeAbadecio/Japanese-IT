"""API server for the iPad app: submit a link, file or text; get back vocabulary and grammar."""
import csv
import io
import json
import re
import shutil
import threading
import time
import uuid
from pathlib import Path

from fastapi import Body, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse

from . import extract, vocab

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
JOBS = DATA / "jobs"
KNOWN = DATA / "known.json"
JOBS.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Japanese Study")
_lock = threading.Lock()

# Jobs that were mid-run when the server stopped will never finish; mark them failed.
# Grammar is found by the iPad app; jobs from before that get `grammar: None` so the app finds it.
for _p in JOBS.glob("*.json"):
    _j = json.loads(_p.read_text())
    if _j.get("status") == "running":
        _j.update(status="error", progress="Interrupted because the server restarted. Try again.")
        _p.write_text(json.dumps(_j, ensure_ascii=False))
    if "grammar_error" in _j:
        _j.pop("grammar_error")
        if not _j.get("grammar"):
            _j["grammar"] = None
        _p.write_text(json.dumps(_j, ensure_ascii=False))


def save_job(job: dict):
    with _lock:
        tmp = JOBS / f"{job['id']}.json.tmp"
        tmp.write_text(json.dumps(job, ensure_ascii=False))
        tmp.replace(JOBS / f"{job['id']}.json")


def load_job(job_id: str) -> dict:
    path = JOBS / f"{job_id}.json"
    if not path.exists() or "/" in job_id:
        raise HTTPException(404, "Not found")
    return json.loads(path.read_text())


def load_known() -> dict:
    """Familiar words, keyed by dictionary form. They are hidden from every word list and Anki export."""
    return json.loads(KNOWN.read_text()) if KNOWN.exists() else {}


def save_known(known: dict):
    tmp = KNOWN.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(known, ensure_ascii=False))
    tmp.replace(KNOWN)


def unknown_vocab(job: dict, known: dict | None = None) -> list[dict]:
    known = load_known() if known is None else known
    return [v for v in job.get("vocab") or [] if v["word"] not in known]


def run_job(job: dict, source: dict):
    workdir = extract.new_workdir()

    def progress(msg: str):
        job["progress"] = msg
        save_job(job)

    try:
        if source["kind"] == "url":
            title, text = extract.from_url(source["url"], workdir, progress)
        elif source["kind"] == "file":
            title, text = extract.from_file(Path(source["path"]), progress)
        else:
            title, text = source.get("title") or "Pasted text", source["text"]

        text = text.strip()
        if not text:
            raise RuntimeError("No text could be found in that source.")
        job.update(title=job.get("title") or title, transcript=text)

        progress("Building vocabulary list")
        job["vocab"] = vocab.build(text, progress)
        if not job["vocab"]:
            raise RuntimeError("No Japanese words were found. Check the link, or that the video has Japanese audio.")
        save_job(job)

        job.update(status="done", progress="Done")  # the iPad app finds grammar next
    except Exception as e:  # surface any failure to the phone instead of hanging
        msg = str(e) if isinstance(e, RuntimeError) else f"{type(e).__name__}: {e}"
        job.update(status="error", progress=msg)
    finally:
        job["finished_at"] = time.time()
        save_job(job)
        shutil.rmtree(workdir, ignore_errors=True)
        if source["kind"] == "file":
            Path(source["path"]).unlink(missing_ok=True)


def start(source: dict, title: str | None) -> dict:
    job = {"id": uuid.uuid4().hex[:12], "status": "running", "progress": "Starting",
           "title": title, "source": source.get("url") or source.get("name") or "text",
           "created_at": time.time(), "vocab": [], "grammar": None}
    save_job(job)
    threading.Thread(target=run_job, args=(job, source), daemon=True).start()
    return job


@app.post("/api/jobs")
async def create_job(url: str = Form(""), text: str = Form(""), title: str = Form(""),
                     file: UploadFile | None = File(None)):
    if file and file.filename:
        uploads = DATA / "uploads"
        uploads.mkdir(exist_ok=True)
        dest = uploads / f"{uuid.uuid4().hex[:8]}{Path(file.filename).suffix.lower()}"
        with dest.open("wb") as out:
            while chunk := await file.read(1 << 20):
                out.write(chunk)
        job = start({"kind": "file", "path": str(dest), "name": file.filename}, title or Path(file.filename).stem)
    elif url.strip():
        job = start({"kind": "url", "url": url.strip()}, title or None)
    elif text.strip():
        job = start({"kind": "text", "text": text, "title": title}, title or text.strip()[:20])
    else:
        raise HTTPException(400, "Paste a link, choose a file, or paste some text.")
    return {"id": job["id"]}


@app.get("/api/jobs")
def list_jobs():
    jobs, known = [], load_known()
    for p in JOBS.glob("*.json"):
        j = json.loads(p.read_text())
        jobs.append({k: j.get(k) for k in ("id", "title", "status", "progress", "source", "created_at")}
                    | {"vocab_count": len(unknown_vocab(j, known)), "grammar_count": len(j.get("grammar") or [])})
    return sorted(jobs, key=lambda j: -j["created_at"])


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str):
    job = load_job(job_id)
    vocab = unknown_vocab(job)
    return job | {"vocab": vocab, "known_hidden": len(job.get("vocab") or []) - len(vocab)}


@app.put("/api/jobs/{job_id}/grammar")
def save_grammar(job_id: str, grammar: list[dict] = Body(...), truncated: bool = Body(False), skipped: int = Body(0)):
    """Saves grammar the iPad app found with Apple Intelligence."""
    job = load_job(job_id)
    job.update(grammar=grammar, grammar_truncated=truncated, grammar_skipped=skipped)
    save_job(job)
    return {"ok": True, "count": len(grammar)}


@app.delete("/api/jobs/{job_id}")
def delete_job(job_id: str):
    load_job(job_id)
    (JOBS / f"{job_id}.json").unlink()
    return {"ok": True}


@app.get("/api/jobs/{job_id}/anki.csv")
def anki_csv(job_id: str):
    job = load_job(job_id)
    buf = io.StringIO()
    w = csv.writer(buf)
    for v in unknown_vocab(job):
        w.writerow([v["word"], v["reading"], "; ".join(v.get("meanings", [])), v.get("example", "")])
    for g in job.get("grammar") or []:
        ex = g["examples"][0] if g.get("examples") else {"japanese": "", "english": ""}
        w.writerow([g["pattern"], g.get("jlpt", ""), f"{g['meaning']} — {g['explanation']}",
                    f"{ex['japanese']} ({ex['english']})"])
    return PlainTextResponse(buf.getvalue(), media_type="text/csv",
                             headers={"Content-Disposition": f'attachment; filename="{job_id}-anki.csv"'})


@app.get("/api/known")
def list_known():
    return sorted(load_known().values(), key=lambda k: -k["added_at"])


@app.post("/api/known")
def add_known(words: str = Form(...), exact: bool = Form(False)):
    """Mark words as familiar. Accepts one word or many separated by spaces, commas or new lines.
    Typed words are turned into dictionary form; `exact` keeps a word from a word list as it is."""
    added = []
    with _lock:
        known = load_known()
        for raw in dict.fromkeys(w for w in re.split(r"[\s,、，;；/／]+", words) if w):
            entry = vocab.normalize(raw)
            if exact and entry["word"] != raw:
                entry = entry | {"word": raw, "reading": vocab.to_hiragana(raw) if not vocab.KANJI.search(raw) else entry["reading"]}
            if entry["word"] not in known:
                known[entry["word"]] = entry | {"added_at": time.time()}
                added.append(entry["word"])
        save_known(known)
    return {"added": added, "total": len(known)}


@app.delete("/api/known/{word}")
def remove_known(word: str):
    with _lock:
        known = load_known()
        if known.pop(word, None) is None:
            raise HTTPException(404, "Not in your familiar words")
        save_known(known)
    return {"ok": True}
