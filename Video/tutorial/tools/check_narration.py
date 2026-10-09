"""Transcribe each narration cue with the local Whisper model and print it beside its script line.
A check for dropped, repeated or misread words; run with the qwen-tts environment's Python."""
import json, pathlib, sys
from mlx_audio.stt.utils import load_model

ROOT = pathlib.Path(__file__).resolve().parent.parent
script = json.loads((ROOT / sys.argv[1]).read_text())
model = load_model("mlx-community/whisper-large-v3-turbo-asr-fp16")
for cue in script["cues"]:
    wav = ROOT / "build/audio" / script["lang"] / f"{cue['id']}.wav"
    heard = model.generate(str(wav), language=script["lang"]).text.strip()
    print(f"{cue['id']}  script: {','.join(p['say'] for p in cue['parts'])}\n     heard:  {heard}")
