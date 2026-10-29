#!/usr/bin/env python3
"""Generate this project's own moving-color/beep fixtures. FFmpeg is a dev tool,
not linked to the application. No upstream media or source code is consumed."""
import base64, hashlib, math, pathlib, struct, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
output = root / 'Tests/BiliMacTests/Fixtures'
with tempfile.TemporaryDirectory(prefix='bilimac-media-') as temp:
    temp = pathlib.Path(temp)
    with (temp/'colors.rgb').open('wb') as video:
        for frame in range(192):
            image = bytearray()
            for y in range(96):
                for x in range(160):
                    active = abs(x-(frame*2 % 160)) < 9 and 24 <= y < 72
                    image.extend((240,230,40) if active else (x*255//160,y*255//96,40+frame%120))
            video.write(image)
    with (temp/'beeps.pcm').open('wb') as audio:
        for sample in range(48000*8):
            active = sample % 48000 < 6000
            audio.write(struct.pack('<h',int(7000*math.sin(2*math.pi*660*sample/48000)) if active else 0))
    common = ['ffmpeg','-hide_banner','-loglevel','error','-y']
    subprocess.run(common+['-f','rawvideo','-pixel_format','rgb24','-video_size','160x96','-framerate','24','-i',str(temp/'colors.rgb'),'-an','-c:v','libx264','-profile:v','baseline','-pix_fmt','yuv420p','-g','24','-keyint_min','24','-sc_threshold','0','-bf','0','-movflags','empty_moov+default_base_moof+frag_keyframe+global_sidx',str(temp/'bilimac-colors.mp4')],check=True)
    subprocess.run(common+['-f','s16le','-ar','48000','-ac','1','-i',str(temp/'beeps.pcm'),'-vn','-c:a','aac','-b:a','96000','-frag_duration','1000000','-movflags','empty_moov+default_base_moof+global_sidx',str(temp/'bilimac-beeps.mp4')],check=True)
    for name in ['bilimac-colors.mp4','bilimac-beeps.mp4']:
        data = (temp/name).read_bytes()
        (output/(name+'.base64')).write_bytes(base64.encodebytes(data))
        print(name,len(data),hashlib.sha256(data).hexdigest())
    print(subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0])
