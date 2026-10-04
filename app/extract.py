"""Turn a link, an uploaded file, or pasted text into plain Japanese text."""
import re
import tempfile
from pathlib import Path

import requests
from bs4 import BeautifulSoup

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg", ".opus"}
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"


def from_file(path: Path, progress) -> tuple[str, str]:
    """Returns (title, text)."""
    ext = path.suffix.lower()
    title = path.stem
    if ext in VIDEO_EXT:
        return title, transcribe(path, progress)
    if ext == ".pdf":
        progress("Reading PDF")
        from pypdf import PdfReader
        reader = PdfReader(str(path))
        return title, "\n".join((p.extract_text() or "") for p in reader.pages)
    if ext == ".epub":
        progress("Reading EPUB")
        return title, _epub_text(path)
    if ext in {".srt", ".vtt", ".ass"}:
        return title, clean_subtitles(path.read_text(errors="ignore"))
    if ext in {".html", ".htm"}:
        return title, _html_text(path.read_text(errors="ignore"))
    return title, path.read_text(errors="ignore")


def from_url(url: str, workdir: Path, progress) -> tuple[str, str]:
    """Video pages go through yt-dlp (subtitles first, Whisper second); anything else is read as an article."""
    import yt_dlp

    if not url.startswith(("http://", "https://")) and not url.startswith("ytsearch"):
        url = "https://" + url
    progress("Looking up the link")
    try:
        with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "noprogress": True, "skip_download": True}) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception:
        info = None

    if not info or info.get("_type") == "playlist" and not info.get("entries"):
        if not url.startswith("http"):
            raise RuntimeError("Couldn't find a video or page at that link.")
        progress("Reading the web page")
        html = requests.get(url, timeout=30, headers={"User-Agent": "Mozilla/5.0"}).text
        soup = BeautifulSoup(html, "html.parser")
        title = soup.title.get_text(strip=True) if soup.title else url
        return title, _html_text(html)

    if info.get("_type") == "playlist":
        info = info["entries"][0]
    title = info.get("title") or url

    lang = choose_subtitle_lang(info)
    if lang:
        kind, code = lang
        progress(f"Downloading Japanese subtitles ({'official' if kind == 'subtitles' else 'auto-generated'})")
        opts = {
            "quiet": True, "no_warnings": True, "noprogress": True, "skip_download": True,
            "writesubtitles": kind == "subtitles", "writeautomaticsub": kind == "automatic_captions",
            "subtitleslangs": [code], "subtitlesformat": "vtt/srt/best",
            "outtmpl": str(workdir / "subs.%(ext)s"),
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([info.get("webpage_url") or url])
        subs = [p for p in workdir.iterdir() if p.name.startswith("subs.")]
        if subs:
            text = clean_subtitles(subs[0].read_text(errors="ignore"))
            if text.strip():
                return title, text

    progress("No Japanese subtitles, downloading audio")
    opts = {"quiet": True, "no_warnings": True, "noprogress": True, "format": "bestaudio/best",
            "outtmpl": str(workdir / "audio.%(ext)s")}
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([info.get("webpage_url") or url])
    audio = next(p for p in workdir.iterdir() if p.name.startswith("audio."))
    return title, transcribe(audio, progress)


def choose_subtitle_lang(info: dict):
    subs = info.get("subtitles") or {}
    for code in subs:
        if code == "ja" or code.startswith("ja-") or code.startswith("ja_"):
            return "subtitles", code
    autos = info.get("automatic_captions") or {}
    if "ja-orig" in autos:
        return "automatic_captions", "ja-orig"
    # Plain "ja" auto captions are machine translations unless the video itself is Japanese.
    if "ja" in autos and (info.get("language") or "").startswith("ja"):
        return "automatic_captions", "ja"
    return None


def transcribe(path: Path, progress) -> str:
    progress("Transcribing audio with Whisper (first run downloads the model)")
    import mlx_whisper
    result = mlx_whisper.transcribe(str(path), path_or_hf_repo=WHISPER_MODEL, language="ja")
    return "\n".join(seg["text"].strip() for seg in result.get("segments", [])) or result.get("text", "")


def clean_subtitles(raw: str) -> str:
    lines, last = [], None
    for line in raw.splitlines():
        line = line.strip()
        if not line or line == "WEBVTT" or "-->" in line or line.isdigit():
            continue
        if line.startswith("Dialogue:"):
            line = line.split(",", 9)[-1].replace("\\N", " ")
        elif line.startswith(("Kind:", "Language:", "NOTE", "STYLE", "[", "Format:", "Style:")) or ":" in line[:12] and line.isascii():
            continue
        line = re.sub(r"<[^>]+>|\{[^}]*\}", "", line).strip()
        if line and line != last:
            lines.append(line)
            last = line
    return "\n".join(lines)


def _html_text(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "nav", "header", "footer", "rt", "rp"]):
        tag.decompose()
    root = soup.find("article") or soup.find("main") or soup.body or soup
    return "\n".join(s.strip() for s in root.get_text("\n").splitlines() if s.strip())


def _epub_text(path: Path) -> str:
    import ebooklib
    from ebooklib import epub
    book = epub.read_epub(str(path))
    parts = [_html_text(item.get_content().decode("utf-8", "ignore"))
             for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT)]
    return "\n".join(p for p in parts if p)


def new_workdir() -> Path:
    return Path(tempfile.mkdtemp(prefix="jpstudy-"))
