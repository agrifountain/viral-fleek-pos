from PIL import Image, ImageDraw, ImageFont
f0='/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'
for size in (192,512):
    im=Image.new('RGB',(size,size),(184,21,90));d=ImageDraw.Draw(im);f=ImageFont.truetype(f0,int(size*0.40))
    bb=d.textbbox((0,0),'VF',font=f);w,hh=bb[2]-bb[0],bb[3]-bb[1];d.text(((size-w)/2-bb[0],(size-hh)/2-bb[1]),'VF',fill=(255,255,255),font=f);im.save(f'icon-{size}.png')
