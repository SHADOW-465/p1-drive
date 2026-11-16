class_name AudioBake
extends RefCounted
## Synthesizes the car's AudioStreamWAV loops once at startup (PLAN 6.5). No audio files.

const RATE: int = 22050

static var _cache: Dictionary = {}


static func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i: int in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
	return w


## 1 s loop of integer-frequency partials (seamless), soft-clipped for grit.
static func tones(key: String, freqs: PackedFloat32Array, amps: PackedFloat32Array, drive: float) -> AudioStreamWAV:
	if not _cache.has(key):
		var out := PackedFloat32Array()
		out.resize(RATE)
		for i: int in RATE:
			var ph: float = TAU * i / RATE
			var s: float = 0.0
			for k: int in freqs.size():
				s += amps[k] * sin(ph * freqs[k] + k * 1.3)
			out[i] = tanh(s * drive) * 0.8
		_cache[key] = _wav(out, true)
	return _cache[key]


## Low-passed noise (+ optional sine). secs long; loops are crossfaded at the seam, one-shots decay.
static func noise(key: String, secs: float, lowpass: float, sine_hz: float, loop: bool) -> AudioStreamWAV:
	if not _cache.has(key):
		var cnt: int = int(RATE * secs)
		var fade: int = cnt / 8
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(key)
		var raw := PackedFloat32Array()
		raw.resize(cnt + fade)
		var y: float = 0.0
		for i: int in cnt + fade:
			y += (rng.randf_range(-1.0, 1.0) - y) * lowpass
			raw[i] = y / sqrt(lowpass) * 0.5 + (0.25 * sin(TAU * sine_hz * i / RATE) if sine_hz > 0.0 else 0.0)
		var out := PackedFloat32Array()
		out.resize(cnt)
		for i: int in cnt:
			if loop:
				out[i] = lerpf(raw[cnt + i], raw[i], float(i) / fade) if i < fade else raw[i]
			else:
				out[i] = raw[i] * exp(-6.0 * i / cnt) * minf(i / 200.0, 1.0)
		_cache[key] = _wav(out, loop)
	return _cache[key]
