"""Write the qtts batch for a script file and run it. One job per cue: the parts of a cue are
joined with commas, because this voice stalls on a full stop inside a job (local-voice skill)."""
import json, subprocess, sys, pathlib, hashlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
QTTS = pathlib.Path.home() / "Documents/qwen-tts"


def main(script_path):
    script = json.loads(pathlib.Path(script_path).read_text())
    out_dir = ROOT / "build/audio" / script["lang"]
    out_dir.mkdir(parents=True, exist_ok=True)
    texts_path = out_dir / "_texts.json"
    old = json.loads(texts_path.read_text()) if texts_path.exists() else {}
    jobs, texts = [], {}
    for cue in script["cues"]:
        comma, stop = (",", "。") if script["lang"] == "zh" else (", ", ".")
        text = comma.join(p["say"] for p in cue["parts"]) + stop
        texts[cue["id"]] = hashlib.sha1(text.encode()).hexdigest()
        wav = out_dir / f"{cue['id']}.wav"
        if wav.exists() and old.get(cue["id"]) != texts[cue["id"]]:
            replaced = out_dir / "_replaced"
            replaced.mkdir(exist_ok=True)
            wav.rename(replaced / f"{cue['id']}-{old.get(cue['id'], 'unknown')[:8]}.wav")
        jobs.append({"text": text, "out": str(wav)})
    batch = out_dir / "_jobs.json"
    batch.write_text(json.dumps({"lang": script["lang"], "overwrite": False, "jobs": jobs}, ensure_ascii=False, indent=1))
    subprocess.run([str(QTTS / "mlxenv/bin/python"), str(QTTS / "qtts.py"), "batch", str(batch)], check=True)
    texts_path.write_text(json.dumps(texts, indent=1))
    missing = [j["out"] for j in jobs if not pathlib.Path(j["out"]).exists()]
    print(f"cues {len(jobs)}  missing {len(missing)}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main(sys.argv[1])
