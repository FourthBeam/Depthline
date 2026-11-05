#!/usr/bin/env python3
"""Author Depthline's procedural campaign assets without reading any legacy asset.

Numeric node IDs are an internal adapter contract with the existing simulation.
All vertices, hit volumes, terrain and mission declarations below are newly authored.
"""
import hashlib, json, math, struct, zlib
from bisect import bisect_right
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'original-assets' / 'scenes'

def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')))

def png(path, width, height, pixels):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\0' + bytes(pixels[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))

# The western bluffs are three successive spurs on one mainland. The middle
# of the beach is gentler and the eastern inlet bends back toward the battery.
SHORE_KNOTS = [(-300,-473),(-223,-448),(-180,-491),(-163,-460),(-147,-328),
               (-128,-351),(-115,-329),(-101,-216),(-88,-232),(-78,-168),
               (-68,-133),(-43,-95),(-18,-78),(0,-67),(25,-51),(48,-43),
               (74,-45),(103,-62),(132,-93),(170,-108),(218,-103),(300,-150)]

def smooth(a, b, x):
    t = max(0, min(1, (x - a) / (b - a)))
    return t*t*(3-2*t)

def shore_sample(x):
    i = max(0, min(len(SHORE_KNOTS)-2, bisect_right(SHORE_KNOTS, (x, math.inf))-1))
    def slope(j):
        a,b = SHORE_KNOTS[j:j+2]
        return (b[1]-a[1])/(b[0]-a[0])
    def tangent(j):
        if j == 0: return slope(0)
        if j == len(SHORE_KNOTS)-1: return slope(j-1)
        left,right = slope(j-1),slope(j)
        return 2*left*right/(left+right) if left*right > 0 else 0
    (xa,za),(xb,zb) = SHORE_KNOTS[i:i+2]
    t = max(0, min(1,(x-xa)/(xb-xa)))
    return round(za*(1-t)**2*(1+2*t) + zb*t*t*(3-2*t)
                 + (xb-xa)*t*(1-t)*((1-t)*tangent(i)-t*tangent(i+1)), 4)

SHORE = [shore_sample(x) for x in range(-300,301)]

@lru_cache(maxsize=2048)
def shore_at(x):
    u = max(0,min(600,x+300))
    i = min(599,int(u))
    return SHORE[i] + (SHORE[i+1]-SHORE[i])*(u-i)

@lru_cache(maxsize=2048)
def shore_normal_z(x):
    return 1/math.hypot(1,(shore_at(x+1)-shore_at(x-1))*.5)

def shore_distance(x,z):
    return (z-shore_at(x))*shore_normal_z(x)

def coast_ground(x,z):
    d=shore_distance(x,z)
    if d <= 0: return max(-9,d*.14)
    ramp=min(1,d/61)
    beach=6.55*ramp + ramp*(.34*math.sin(x*.079+z*.049)+.25*math.cos(z*.11))
    # Windblown sand builds behind the left shoulder, clear of the ramp paths.
    beach += 1.6*math.exp(-((x+24)/16)**2-((z+35)/15)**2)*ramp
    western=smooth(46,80,-x)
    exposure=western + .56*smooth(99,152,x)
    # Three eroded beds with narrow risers. Fracture notches break the crest
    # on 8–17 m scales and are shared by foot/track contacts and the mesh.
    faceHeight = 5.2+5*smooth(89,141,-x)+2.1*math.sin(x*.087)
    notch = abs(math.sin(x*.235+z*.123))+.72*abs(math.sin(x*.41-z*.086))
    cut = d - 1.8*math.sin(x*.16+z*.044) - notch
    bank=faceHeight*(.27*smooth(3,4.2,cut)+.46*smooth(6.4,8.0,cut)+.27*smooth(10.2,11.4,cut))
    bank+=smooth(14,25,cut)*(3.4+1.2*math.sin(z*.073+x*.081))-1.5*notch*smooth(3,10,cut)
    return beach + exposure*bank

def ground(x, z, coast):
    if coast: return coast_ground(x,z)
    # A low saddle leads armour towards the battery. Two oblique spurs
    # branch from it; both the triangles and the 1 m contact grid sample this.
    r = math.hypot(x, z)
    u = min(1.0, max(0.0, (r-12.0)/62.0))
    u = u*u*(3.0-2.0*u)
    spur = 11.5*math.exp(-((x+65-.30*z)/34)**2-((z-108)/98)**2)
    fork = 16*math.exp(-((x-90+.23*z)/40)**2-((z-192)/107)**2)
    folds = (math.sin(x*.037+z*.019)*math.cos(z*.033)*1.85
             + math.sin(x*.079-z*.053)*.44)
    return 6.0 + u*(spur+fork+folds+max(0, r-120)*.037)

def group(vertices, indices, normals=None, texture=None, color=(.45, .46, .40), uvs=None):
    g = {'vertices': vertices, 'indices': indices, 'normals': normals or [0, 1, 0] * (len(vertices)//3), 'color': list(color), 'polyType': 'Textured' if texture is not None else 'Coloured'}
    if texture is not None: g['texture'] = texture
    if uvs is not None: g['uvs'] = uvs
    return g

def placeholder():
    # Hidden when a procedural rigid part is installed; no borrowed geometry.
    return group([-.1,0,0,.1,0,0,0,.1,0], [0,1,2])

def scene_objects(coast):
    objects = {}
    def node(i, name, parent=None, pos=(0,0,0), groups=None):
        o = {'id':i, 'name':name, 'translation':list(pos), 'groups':groups if groups is not None else [placeholder()]}
        if parent is not None: o['link'] = parent
        objects[i] = o
    if coast:
        node(8,'Gun Mount',pos=(0,800,0)); node(9,'LeftGun',8); node(10,'RightGun',8)
        node(142,'CanonMount',pos=(0,800,0)); node(143,'Cannon',142)
        node(214,'Pistol',142,(5,-10,-70)); node(215,'PistolSlide',214)
        node(11,'Barge');node(23,'BargeRamp',11,(0,32,-430))
        node(17,'BargeVehicle');node(29,'BargeRamp',17,(0,44,-600))
        node(37,'Tank1');node(43,'Tank1',37,(0,145,0));node(49,'Tank1',43,(0,0,-60));node(55,'Tank1',49)
        node(61,'APC');node(67,'Ramp',61,(0,29,152))
        node(73,'Bomber');node(76,'Jet')
        node(88,'Cobra1');node(94,'Rotor',88);node(100,'Prop',88,(0,-52,538))
        node(106,'CH53');node(109,'Ramp',106,(0,-289,307));node(112,'Rotor',106);node(115,'Prop',106,(-60,19,905))
        node(207,'C130')
        for i,x in enumerate([-610,-300,300,610]):node(208+i,'Prop'+str(i),207,(x,93,-240))
        node(212,'Parachute1');node(213,'Parachute2');node(161,'Missile1');node(163,'Rocket1');node(175,'Bomb1');node(218,'Grenades')
    else:
        node(19,'Mount',pos=(0,800,0));node(20,'TwinMount',19);node(21,'LeftGun',20);node(22,'RightGun',20)
        node(23,'Automatic',19,(8,10,-25));node(24,'Cannon',19);node(25,'Rotary',19,(8,7.6,-25))
        node(26,'Pistol',19,(5,-10,-70));node(27,'PistolSlide',26);node(28,'Flaregun',19,(5,-10,-70))
        node(37,'Tank1');node(49,'Turret',37);node(61,'TMount',49,(0,130,-60))
        node(73,'APC');node(85,'Ramp',73,(0,30,164))
        node(77,'APC2');node(89,'Ramp',77,(0,30,164));node(97,'AGunTurret',77);node(105,'APCGun',97,(0,175,-47))
        node(81,'APC3');node(93,'Ramp',81,(0,30,164));node(101,'AMissileTurret',81);node(109,'Launcher',101,(0,160,0));node(113,'Radar',101)
        node(117,'Jet');node(133,'Bomber')
        node(142,'Cobra1');node(154,'Rotor',142);node(166,'Prop',142,(0,-52,538))
        node(178,'CH53');node(186,'Ramp',178,(0,-289,307));node(194,'Rotor',178);node(202,'Prop',178,(-60,19,905))
        node(210,'C130')
        for i,x in enumerate([-610,-300,300,610]):node(218+i*8,'Prop'+str(i),210,(x,93,-240))
        for i,name in enumerate(['Parachute','HealthBoxes','AmmoBoxes','MissileBoxes','MISSILE','ROCKETS','BOMBS','Grenades','ProjectileBoxes']):node(450+i,name)
    # Terrain: meter grid, smooth finite-difference normals, original coast/hills.
    v,n,uv,idx=[],[],[],[]
    dim=301
    # Extend the coast beyond the playable heightmap so distant capes meet the sea.
    z_rows=(list(range(-544,-300,4)) if coast else []) + list(range(-300,301,2))
    for row,z in enumerate(z_rows):
        for col in range(dim):
            x=-300+col*2; y=ground(x,z,coast)
            v.extend([x*100,round(y*100,3),z*100]);uv.extend([col/(dim-1), min(1,max(0,(300-z)/600))])
            nx=ground(x-1,z,coast)-ground(x+1,z,coast);nz=ground(x,z-1,coast)-ground(x,z+1,coast)
            length=math.sqrt(nx*nx+4+nz*nz);n.extend([nx/length,2/length,nz/length])
    for row in range(len(z_rows)-1):
        for col in range(dim-1):
            a=row*dim+col;b=a+1;c=a+dim;d=c+1
            idx.extend([a,c,b,b,c,d])
    node(10000,'TerrainDepthline',groups=[group(v,idx,n,1,uvs=uv)])
    if coast:
        wv,wi,wu=[],[],[];cols=301;rows=192
        for row in range(rows):
            for col in range(cols):
                wv.extend([(-600+col*4)*100,0,(-802+row*4)*100]);wu.extend([col/300,row/185])
        for row in range(rows-1):
            for col in range(cols-1):
                a=row*cols+col;b=a+1;c=a+cols;d=c+1;wi.extend([a,c,b,b,c,d])
        node(10001,'SkyDay',groups=[group(wv,wi,texture=2,uvs=wu)])
    return list(objects.values())

def box_polygons(center, size):
    x,y,z=center;a,b,c=[v/2 for v in size]
    p=[[x+sx*a,y+sy*b,z+sz*c] for sx,sy,sz in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    return [[p[i] for i in face] for face in [(0,3,2,1),(4,5,6,7),(0,4,7,3),(1,2,6,5),(0,1,5,4),(3,7,6,2)]]

def collisions(coast):
    shapes={'TANK':[((0,80,30),(230,140,440)),((0,165,10),(180,70,200))],
      'APC':[((0,85,0),(190,170,380))], 'JET':[((0,0,0),(190,120,620)),((0,0,80),(780,30,180))],
      'BOMBER':[((0,0,0),(280,210,1400)),((0,0,100),(1800,50,360))],
      'COBRA':[((0,-95,0),(150,170,700))], 'CH53':[((0,-120,0),(330,310,1050))],
      'C130':[((0,-50,0),(350,350,1800)),((0,40,80),(2500,65,500))],
      'BARGE1':[((0,30,0),(260,110,880))], 'BARGE2':[((0,40,0),(360,150,1200))]}
    aliases={'TANK':'M48','APC':'M113','JET':'F4','BOMBER':'B52','COBRA':'AH1'} if coast else {}
    objects=[{'name':aliases.get(name,name),'parts':[{'index':i,'polygons':box_polygons(*box)} for i,box in enumerate(boxes)]} for name,boxes in shapes.items()]
    # The fabric and the cargo are separate targets. Leave open air between
    # them. Dimensions are cm; the corresponding render mesh uses metres.
    def ring(rx,y,rz):
        return [[rx*math.cos(i*math.tau/12),y,rz*math.sin(i*math.tau/12)] for i in range(12)]
    rim=ring(158,-12,152); shoulder=ring(122,88,116); crown=[0,140,0]
    dome=[rim]+[[rim[i],rim[(i+1)%12],shoulder[(i+1)%12],shoulder[i]] for i in range(12)]
    dome += [[shoulder[i],shoulder[(i+1)%12],crown] for i in range(12)]
    parts=[{'index':0,'polygons':dome}]
    if coast:
        # Coast models carry an integral 90 cm crate, 4.50 m below the rim.
        parts.append({'index':1,'polygons':box_polygons((0,-450,0),(168,168,168))})
    else:
        # Inland cargo hangs from a separate rotating scene node. Each hull
        # includes a small aim allowance around the straps and crate edges.
        for name,size in [('HealthBoxes',(166,166,166)),('AmmoBoxes',(166,146,166)),
                          ('ProjectileBoxes',(166,166,166)),('MissileBoxes',(132,186,132))]:
            objects.append({'name':name,'parts':[{'index':1,'polygons':box_polygons((0,0,0),size)}]})
    objects.append({'name':'Parachute','parts':parts})
    return {'authorship':'Depthline procedural convex volumes, 2026-11-05','objects':objects}

def levels(coast):
    output=[]
    for level in range(1,61 if coast else 101):
        tier=(level-1)//6; wave=[]
        if coast:
            for slot in range(min(6,2+tier//2)):
                wave.append({'type':'BARGE','slot':slot,'cargoFamily':'infantry','direction':'North','visible':1 if slot<2 else 0,'delay':180+slot*110,'revive':0 if slot<2 else 1})
            for index in range(min(3,tier//2)):
                tank=index%2==0;slot=index//2;boat=(6 if tank else 9)+slot;delay=480+index*150
                wave.extend([{'type':'BARGE','slot':boat,'cargoFamily':'vehicle','direction':'North','visible':0,'delay':delay,'revive':1}, {'type':'TANK' if tank else 'APC1','slot':slot,'visible':0,'delay':delay,'revive':1}])
            for slot in range(min(5,1+tier)):
                wave.append({'type':'COBRA' if slot%2==0 else 'JET','slot':slot,'direction':'North','visible':0,'delay':450+slot*230,'revive':1})
            wave.append({'type':'C130','slot':0,'visible':0,'delay':240,'revive':1})
            output.append({'number':level,'title':f'潮口守备 {level:02}','ammo':[300+tier*80,8+tier*2,3+tier], 'aggression':[min(8,2+tier)]*4,'time':140+tier*12,'artillery':1 if tier>0 else 0,'flags':[],'objects':wave})
        else:
            direction=['South','East','West','North'][(level-1)%4]
            for slot in range(2+min(2,tier//2)):
                wave.append({'type':'APC1','slot':slot,'delay':70+slot*95,'direction':direction})
            for slot in range(min(6,1+tier)):
                wave.append({'type':'COBRA','slot':slot,'delay':350+slot*160,'direction':direction})
            for slot in range(min(8,tier)):
                wave.append({'type':'TANK','slot':slot,'delay':600+slot*120,'direction':direction})
            if tier>1:wave.append({'type':'CH53','slot':0,'delay':850,'direction':direction})
            if tier>2:wave.append({'type':'JET','slot':0,'delay':420,'direction':direction})
            if tier>3:wave.append({'type':'BOMBER','slot':0,'delay':1100,'direction':direction})
            if level>=3:wave.append({'type':'C130','slot':0,'delay':240,'direction':direction,'passes':1,'hdrop':1,'adrop':2,'pdrop':1,'mdrop':1,'troops1':2,'troops2':0})
            night=level%5==0
            flags=['Crosshair','AltGun' if level%3 else 'AltGun2']+(['Spotlight'] if night else ['Daytime'])
            output.append({'number':level,'title':f'丘陵屏障 {level:02}','ammo':[460+tier*80,12+tier,6+tier,8 if night else 0],'aggression':[min(10,2+tier)]*4,'flags':flags,'objects':wave,'groupDirections':{name:direction for name in ['APC','TANK','COBRA','CH53','JET','BOMBER','C130']}})
    return output

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    for game_id,coast,name in [('2000',True,'coast'),('2002',False,'interior')]:
        dest=OUT/name;dest.mkdir(exist_ok=True);(dest/'textures').mkdir(exist_ok=True)
        dim=601
        heights=bytes(min(255,max(0,round(ground(x-300,z-300,coast)/.16))) for z in range(dim) for x in range(dim))
        (dest/'heightmap.bin').write_bytes(heights)
        pixels=[]
        for row in range(256):
            z=-300+row*600/255
            for col in range(256):
                x=-300+col*600/255;y=ground(x,z,coast)
                if coast:
                    d=shore_distance(x,z)
                    drift=math.sin(x*.051+z*.032)*.55+math.sin(z*.153-x*.093)*.28+math.cos(x*.196+z*.13)*.17
                    grass=smooth(30,57,d+drift*17+max(0,-x-84)*.64)
                    color=tuple(round((warm*(1-grass)+green*grass)*(1+.082*drift)) for warm,green in zip((155,140,112),(98,112,74)))
                else:
                    # Surface zones in metres: olive low meadow, drier outward
                    # facing shoulders and grey fans below the two high spurs.
                    fold=math.sin(x*.046-z*.064+.72*math.sin(z*.11))*.55+math.cos(x*.091+z*.073)*.25+math.sin(z*.22+x*.14)*.12
                    dry=smooth(.12,.8,fold+(y-9)*.034)
                    scree=smooth(.63,1.1,fold+(y-10)*.087)
                    color=tuple(round((green*(1-dry)+gold*dry)*(1-scree)+grey*scree) for green,gold,grey in zip((91,117,77),(136,124,88),(119,119,113)))
                pixels.extend([*color,255])
        png(dest/'textures/TerrainDepthline.png',256,256,pixels)
        png(dest/'textures/OceanDepthline.png',2,2,[35,65,83,255]*4)
        glow=[]
        for y in range(64):
            for x in range(64):
                a=int(255*math.exp(-((x-31.5)**2+(y-31.5)**2)/80));glow.extend([255,218,147,a])
        png(dest/'textures/Glow.png',64,64,glow)
        objects=scene_objects(coast)
        scene={'schemaVersion':1,'product':'depthline','gameID':game_id,'authorship':'Original Depthline procedural scenery and mechanical adapter pivots','objects':objects,
          'heightmap':{'file':'heightmap.bin','width':dim,'height':dim,'originX':-30000,'originZ':-30000,'spacing':100,'heightScale':16},
          'textures':[{'id':1,'file':'textures/TerrainDepthline.png'},{'id':2,'file':'textures/OceanDepthline.png'},{'id':8,'file':'textures/Glow.png'}], 'animations':[]}
        if coast: scene['shoreline']={'originX':-300,'spacing':1,'z':SHORE}
        write_json(dest/'scene.json',scene);write_json(dest/'levels.json',levels(coast));write_json(dest/'collision.json',collisions(coast))
        # New fragment chunks: seeded simple plate pieces, only IDs match simulation slots.
        fragments=[]
        for i in range(512):
            commands=[]
            for j in range(48):
                x=((i*13+j*7)%31-15)*7; y=(j%5)*12; z=((i*3+j*11)%43-21)*9
                commands.append({'kind':'polygon','group':group([x,y,z,x+19,y+4,z+7,x+5,y+17,z+23],[0,1,2],color=(.19,.20,.18))})
            fragments.append({'id':i,'name':f'Plate{i}','commands':commands})
        write_json(dest/'fragments.json',{'gameID':game_id,'authorship':'Original procedural plate fragments','objects':fragments})
        if coast:
            write_json(dest/'wrecks.json',{'gameID':game_id,'objects':[{'id':i,'name':'Tank1' if i<60 else 'Ramp','translation':[0,0,0],'groups':[placeholder()]} for i in list(range(37,49))+list(range(61,73))]})
    files={str(p.relative_to(OUT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(OUT.rglob('*')) if p.is_file() and p.name!='manifest.json'}
    write_json(OUT/'manifest.json',{'title':'纵深防线','generator':'tools/generate_depthline_assets.py','method':'Mathematical terrain, independently authored waves, convex hit volumes, procedural fragment plates. No legacy data inputs.','files':files})
    print('Generated original Depthline scenes:',len(files),'files')

if __name__=='__main__':main()
