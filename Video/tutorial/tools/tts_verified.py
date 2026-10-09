"""Generate the cues the batch refused, and accept a take only if a transcript of it has the
script's words. The voice service judges completeness by voiced time, calibrated on Chinese;
English is articulated faster and complete takes fail it. Its length and inner-silence checks
are kept. Run with the qtts environment's Python:

    ~/Documents/qwen-tts/mlxenv/bin/python tools/tts_verified.py script.en.json
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
QTTS = pathlib.Path.home() / "Documents/qwen-tts"
sys.path.insert(0, str(QTTS))
import qtts                                           # noqa: E402
import mlx.core as mx                                 # noqa: E402
from mlx_audio.stt.utils import load_model            # noqa: E402


def words(text):
    text = text.lower().replace("it's", "it is").replace("that's", "that is").replace("pdf", "p d f")
    return re.findall(r"[a-z0-9]+|[㐀-鿿]", text)


def main(script_path):
    script = json.loads((ROOT / script_path).read_text())
    lang = script["lang"]
    comma, stop = (",", "。") if lang == "zh" else (", ", ".")
    out_dir = ROOT / "build/audio" / lang
    todo = [c for c in script["cues"] if not (out_dir / f"{c['id']}.wav").exists()]
    if not todo:
        print("nothing missing"); return 0
    voice, listener = qtts._model(), load_model("mlx-community/whisper-large-v3-turbo-asr-fp16")
    failed = 0
    for cue in todo:
        text = comma.join(p["say"] for p in cue["parts"]) + stop
        out, expected = out_dir / f"{cue['id']}.wav", qtts.expected_seconds(text)
        for attempt in range(8):
            mx.random.seed(qtts._seed(text, qtts.DEFAULT_REF) + 1000 + attempt)
            qtts._gen_once(voice, text, out, qtts.DEFAULT_REF, lang, 1600, 0.35 if attempt == 0 else 0.25)
            length, hole = qtts._duration(out), qtts._longest_inner_silence(out)
            heard = listener.generate(str(out), language=lang).text.strip()
            if words(heard) == words(text) and 0.5 * expected <= length <= 1.6 * expected and hole <= qtts.MAX_INNER_SILENCE:
                print(f"OK   {cue['id']}  {length:.1f}s  try {attempt + 1}  heard: {heard}", flush=True)
                break
            print(f"     retry {cue['id']}: {length:.1f}s, hole {hole:.1f}s, heard: {heard}", flush=True)
        else:
            out.unlink(missing_ok=True); failed += 1
            print(f"ERR  {cue['id']}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
