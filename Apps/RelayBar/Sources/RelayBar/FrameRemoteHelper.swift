import Foundation

/// Fixed program, never caller-supplied shell. JSON goes on stdin; paths are not shell arguments.
enum FrameRemoteHelper {
    static func arguments(server: RemoteServer, socket: URL?) throws -> [String] {
        guard SSHArgumentPolicy.isValidHostTarget(server.sshHost),
              SSHArgumentPolicy.areAdditionalArgumentsSafe(server.additionalArguments) else {
            throw RemoteFileError.invalidConnection
        }
        var args = ["-T", "-a", "-x", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ClearAllForwardings=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        if let socket { args += ["-S", socket.path, "-o", "ControlMaster=no"] }
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "python3 -c 'import base64;exec(base64.b64decode(\"" + encoded + "\"))'"
        return args + server.additionalArguments + [server.sshHost, command]
    }

    static let script = #"""
import os, sys, json, stat, hashlib, datetime, uuid, io, base64, signal, resource, subprocess, warnings
signal.alarm(50)
resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
resource.setrlimit(resource.RLIMIT_FSIZE, (8*1024*1024, 8*1024*1024))
if sys.platform.startswith('linux'): resource.setrlimit(resource.RLIMIT_AS, (2*1024**3, 2*1024**3))
MEDIA = {'.jpg', '.jpeg', '.png', '.mp4', '.mov', '.m4v'}
DOCUMENTS = {'.md', '.markdown', '.html', '.htm'}
MARKER = b'Frame Remote Assets 1\n'
NOFOLLOW = os.O_NOFOLLOW

def check_path(path):
    if not isinstance(path, str) or not path.startswith('/') or len(path.encode()) > 16384:
        raise ValueError('Invalid absolute path.')
    if any(x in ('.', '..') for x in path.split('/')) or any(ord(x) < 32 or ord(x) == 127 for x in path):
        raise ValueError('Unsafe path.')
    return os.path.normpath(path)

def directory(path):
    path = check_path(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in path.split('/')[1:]:
            if not name: continue
            nxt = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = nxt
        return fd
    except:
        os.close(fd); raise

def fingerprint(s):
    return hashlib.sha256(('%s:%s:%s:%s:%s' % (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)).encode()).hexdigest()

def identity(s):
    return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns]

def entry(path, s):
    return dict(name=os.path.basename(path), path=path, directory=stat.S_ISDIR(s.st_mode), size=s.st_size,
                modified=datetime.datetime.fromtimestamp(s.st_mtime, datetime.timezone.utc).isoformat(),
                fingerprint=fingerprint(s))

def snapshot(path, expected=None):
    parent = directory(os.path.dirname(check_path(path)))
    try:
        fd = os.open(os.path.basename(path), os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally: os.close(parent)
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode):
        os.close(fd); raise ValueError('Only regular files are supported.')
    if expected and (s.st_size != expected['size'] or expected.get('fingerprint') != fingerprint(s)):
        os.close(fd); raise ValueError('File changed. Refresh the folder and retry.')
    return fd, s

def read_json(path, maximum=2*1024*1024):
    fd, s = snapshot(path)
    with os.fdopen(fd, 'rb') as f:
        if s.st_size > maximum: raise ValueError('JSON exceeds 2 MiB.')
        return json.loads(f.read(maximum+1))

def managed(root, create=False):
    base = os.path.join(root, 'Archive')
    rootfd = directory(root)
    try:
        if create:
            try:
                os.mkdir('Archive', 0o700, dir_fd=rootfd)
                d = os.open('Archive', os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=rootfd)
                try:
                    f = os.open('.frame-remote', os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=d)
                    with os.fdopen(f, 'wb') as out: out.write(MARKER)
                finally: os.close(d)
            except FileExistsError: pass
    finally: os.close(rootfd)
    d = directory(base)
    try:
        f = os.open('.frame-remote', os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK, dir_fd=d)
        with os.fdopen(f, 'rb') as src:
            if not stat.S_ISREG(os.fstat(src.fileno()).st_mode) or src.read(128) != MARKER:
                raise ValueError('This folder was not created by Frame.')
    finally: os.close(d)
    return base

def is_managed(root):
    try: managed(root); return True
    except (OSError, ValueError): return False

def list_folder(root):
    fd = directory(root)
    try:
        names = os.listdir(fd)
        if len(names) > 10000: raise ValueError('This folder exceeds 10,000 entries.')
        out = []
        for name in sorted(names):
            if any(ord(c)<32 or ord(c)==127 for c in name): continue
            if name == 'Archive' and is_managed(root): continue
            s = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode):
                out.append(entry(os.path.join(root,name), s))
        return dict(entries=out)
    finally: os.close(fd)

def record_path(root, ident):
    ident = str(uuid.UUID(ident))
    base = managed(root)
    return os.path.join(base, ident)

def record(root, ident):
    folder = record_path(root, ident)
    data = read_json(os.path.join(folder, '.frame-asset.json'))
    originals = data.get('originals', [])
    if data.get('version') != 1 or not 1 <= len(originals) <= 10000:
        raise ValueError('Invalid asset record.')
    for path in originals:
        check_path(path)
        if os.path.dirname(path) != os.path.dirname(originals[0]) or not path.startswith(root.rstrip('/')+'/'):
            raise ValueError('Asset record escapes its folder.')
        if os.path.relpath(path,root).split('/')[0] == 'Archive':
            raise ValueError('Invalid restore destination.')
    if len({os.path.basename(p) for p in originals}) != len(originals): raise ValueError('Duplicate members.')
    if os.path.splitext(originals[0])[1].lower() not in MEDIA | DOCUMENTS: raise ValueError('Invalid media record.')
    if os.path.splitext(originals[0])[1].lower() in DOCUMENTS and len(originals) != 1: raise ValueError('Documents do not own dependencies.')
    stem=os.path.splitext(originals[0])[0]
    if any(os.path.splitext(p)[1].lower() in MEDIA | DOCUMENTS or not p.startswith(stem+'.') for p in originals[1:]):
        raise ValueError('Invalid companion record.')
    return folder, data

def collection(root):
    try: base = managed(root)
    except FileNotFoundError: return dict(records=[])
    d = directory(base)
    try: names = os.listdir(d)
    finally: os.close(d)
    if len(names)>10000: raise ValueError('Archive exceeds 10,000 records.')
    records=[]
    for ident in sorted(names):
        if ident.startswith('.'): continue
        folder, data = record(root, ident)
        members=[]
        for index,original in enumerate(data['originals']):
            path=os.path.join(folder, os.path.basename(original))
            try: fd,s=snapshot(path)
            except FileNotFoundError:
                # Interrupted paired moves retain a manifest; show recoverable members.
                path=original; fd,s=snapshot(path)
                if identity(s)!=data.get('identities',[])[index]:
                    os.close(fd); raise ValueError('Partial asset changed at '+original)
            os.close(fd); members.append(entry(path,s))
        records.append(dict(id=ident, members=members, originals=data['originals']))
    return dict(records=records)

def move_one(source, destination, expected):
    # Atomic no-clobber publication via a hard link, then unlink only the validated source.
    # Same-volume regular files only. Directory handles prevent parent-symlink traversal.
    a=directory(os.path.dirname(source)); b=directory(os.path.dirname(destination))
    try:
        name=os.path.basename(source); target=os.path.basename(destination)
        s=os.stat(name,dir_fd=a,follow_symlinks=False)
        if not stat.S_ISREG(s.st_mode) or fingerprint(s)!=expected: raise ValueError('File changed during move.')
        os.link(name,target,src_dir_fd=a,dst_dir_fd=b,follow_symlinks=False)
        linked=os.stat(target,dir_fd=b,follow_symlinks=False)
        current=os.stat(name,dir_fd=a,follow_symlinks=False)
        if (linked.st_dev,linked.st_ino)!=(s.st_dev,s.st_ino) or (current.st_dev,current.st_ino)!=(s.st_dev,s.st_ino):
            os.unlink(target,dir_fd=b); raise ValueError('File changed during move.')
        try: os.unlink(name,dir_fd=a)
        except:
            os.unlink(target,dir_fd=b); raise
        return fingerprint(os.stat(target,dir_fd=b,follow_symlinks=False))
    finally: os.close(a); os.close(b)

def move_group(pairs):
    moved=[]
    try:
        # Check every destination before moving any member.
        for src,dst,fp in pairs:
            d=directory(os.path.dirname(dst))
            try:
                try: os.stat(os.path.basename(dst),dir_fd=d,follow_symlinks=False)
                except FileNotFoundError: continue
                raise ValueError('Destination exists; nothing was replaced.')
            finally: os.close(d)
        for src,dst,fp in pairs:
            newfp=move_one(src,dst,fp); moved.append((dst,src,newfp))
    except Exception as error:
        failures=[]
        for src,dst,fp in reversed(moved):
            try: move_one(src,dst,fp)
            except Exception: failures.append(src)
        if failures: raise ValueError('Partial move. Recover remaining files at: '+', '.join(failures)) from error
        raise

def delete(q):
    root=check_path(q['root'])
    members=q['members']
    if not 1<=len(members)<=10000: raise ValueError('Invalid asset members.')
    folder=None
    if q.get('recordID'):
        folder,data=record(root,q['recordID'])
        if [e['path'] for e in members]!=[os.path.join(folder,os.path.basename(p)) for p in data['originals']]:
            raise ValueError('Refresh the archived asset before deleting it.')
    # Validate the whole selected group before unlinking; never recurse.
    parents=[]
    deleted=[]
    try:
        for e in members:
            path=check_path(e['path'])
            if not path.startswith(root.rstrip('/')+'/'): raise ValueError('Asset is outside the opened folder.')
            d=directory(os.path.dirname(path)); parents.append(d)
            s=os.stat(os.path.basename(path),dir_fd=d,follow_symlinks=False)
            if not stat.S_ISREG(s.st_mode) or fingerprint(s)!=e.get('fingerprint'):
                raise ValueError('File changed. Refresh the folder and retry.')
        for e,d in zip(members,parents):
            name=os.path.basename(e['path'])
            if fingerprint(os.stat(name,dir_fd=d,follow_symlinks=False))!=e['fingerprint']:
                raise ValueError('File changed during delete: '+e['path'])
            os.unlink(name,dir_fd=d)
            deleted.append(e['path'])
        if folder:
            os.unlink(os.path.join(folder,'.frame-asset.json')); os.rmdir(folder)
        return {}
    except Exception as error:
        if deleted: raise ValueError(str(error)+'; already deleted: '+', '.join(deleted)) from error
        raise
    finally:
        for d in parents: os.close(d)

def mutate(q):
    root=check_path(q['root'])
    if root=='/': raise ValueError('Choose a folder below the filesystem root.')
    if q['action']=='restore':
        folder,data=record(root,q['recordID'])
        pairs=[]
        for index,original in enumerate(data['originals']):
            src=os.path.join(folder,os.path.basename(original))
            try: fd,s=snapshot(src)
            except FileNotFoundError:
                fd,s=snapshot(original); os.close(fd)
                if identity(s)!=data.get('identities',[])[index]: raise ValueError('Restore destination changed.')
                continue
            os.close(fd)
            pairs.append((src,original,fingerprint(s)))
        move_group(pairs)
        # Only this validated manifest and now-empty asset directory; never recursive deletion.
        os.unlink(os.path.join(folder,'.frame-asset.json')); os.rmdir(folder)
        return {}
    members=q['members']
    if not 1<=len(members)<=10000: raise ValueError('Invalid asset members.')
    originals=[e['path'] for e in members]
    identities=[]
    for e in members:
        path=check_path(e['path'])
        if not path.startswith(root.rstrip('/')+'/') or os.path.relpath(path,root).split('/')[0] == 'Archive':
            raise ValueError('Asset is outside the opened folder.')
        fd,s=snapshot(path,e); identities.append(identity(s)); os.close(fd)
    base=managed(root,True); ident=str(uuid.uuid4()); folder=os.path.join(base,ident)
    os.mkdir(folder,0o700)
    manifest=os.path.join(folder,'.frame-asset.json')
    with open(manifest,'x',encoding='utf8') as f:
        json.dump(dict(version=1,originals=originals,identities=identities),f); f.flush(); os.fsync(f.fileno())
    pairs=[(e['path'],os.path.join(folder,e['name']),e['fingerprint']) for e in members]
    try: move_group(pairs)
    except:
        if os.listdir(folder)==['.frame-asset.json']: os.unlink(manifest); os.rmdir(folder)
        raise
    return dict(recordID=ident)

def delete_batch(q):
    batch=q.get('batch',[])
    if not 1<=len(batch)<=500: raise ValueError('Invalid batch size.')
    outcomes=[]
    for asset in batch:
        path=asset['members'][0]['path']
        try:
            if asset['action']!='delete' or asset['root']!=q['root']: raise ValueError('Invalid batch target.')
            delete(asset)
            outcomes.append(dict(path=path))
        except Exception as error:
            outcomes.append(dict(path=path,error=str(error)[:2000]))
    return dict(outcomes=outcomes)

def bounded(value):
    if isinstance(value, bytes): return value[:24000].decode('utf8','replace')
    return str(value)[:24000]

def preview(q):
    members=q['members']
    if not 1<=len(members)<=10000: raise ValueError('Invalid asset.')
    opened=[]
    try:
        for e in members: opened.append(snapshot(e['path'],e))
        token=hashlib.sha256('|'.join(fingerprint(s) for fd,s in opened).encode()).hexdigest()
        if token==q.get('fingerprint'): return dict(fingerprint=token,unchanged=True)
        fd,s=opened[0]; ext=os.path.splitext(members[0]['name'])[1].lower()
        pixels=q.get('pixels',0)
        if pixels not in (0,512,2048): raise ValueError('Invalid preview size.')
        meta={'File size':str(s.st_size),'Modified':members[0]['modified']}
        text={}; image=None; sidecar=None; companions=[]
        if ext in ('.jpg','.jpeg','.png'):
            try:
                from PIL import Image, ImageOps, ExifTags, PngImagePlugin
            except ImportError: raise ValueError('Install Pillow for Python 3 on this host to show previews and metadata.')
            Image.MAX_IMAGE_PIXELS=80000000
            PngImagePlugin.MAX_TEXT_CHUNK=1024*1024; PngImagePlugin.MAX_TEXT_MEMORY=2*1024*1024
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with os.fdopen(os.dup(fd),'rb') as src, Image.open(src) as im:
                meta['Dimensions']='%s × %s'%im.size
                im.load()
                for key,value in list(im.info.items())[:128]:
                    if isinstance(value,(str,int,float)): text[str(key)]=bounded(value)
                exif=im.getexif()
                try: exif.update(exif.get_ifd(34665))
                except (KeyError,ValueError,TypeError): pass
                for key,value in list(exif.items())[:128]:
                    meta[ExifTags.TAGS.get(key,str(key))]=bounded(value)
                if pixels:
                    im.draft('RGB',(pixels,pixels))
                    im.thumbnail((pixels,pixels),Image.Resampling.LANCZOS)
                    im=ImageOps.exif_transpose(im)
                    output=io.BytesIO()
                    # PNG preserves alpha; strip metadata from derivatives, retain separately.
                    if 'A' in im.getbands(): im.convert('RGBA').save(output,format='PNG',compress_level=3)
                    else: im.convert('RGB').save(output,format='JPEG',quality=85)
                    image=output.getvalue()
        elif ext in ('.mp4','.mov','.m4v'):
            path='/dev/fd/'+str(fd)
            try:
                probe=subprocess.run(['ffprobe','-v','error','-show_entries','format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate','-of','json',path],
                    pass_fds=(fd,),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=15,check=True)
                data=json.loads(probe.stdout[:65536])
                meta['Duration']=data.get('format',{}).get('duration','')
                for stream in data.get('streams',[])[:16]:
                    if stream.get('codec_type')=='video':
                        meta['Dimensions']='%s × %s'%(stream.get('width','?'),stream.get('height','?'))
                        meta['Codec']=stream.get('codec_name',''); break
                if pixels:
                    os.lseek(fd,0,0)
                    result=subprocess.run(['ffmpeg','-v','error','-threads','1','-i',path,'-frames:v','1','-vf',
                        'scale='+str(pixels)+':'+str(pixels)+':force_original_aspect_ratio=decrease','-f','image2pipe','-vcodec','mjpeg','-q:v','4','pipe:1'],
                        pass_fds=(fd,),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20,check=True)
                    image=result.stdout
            except FileNotFoundError: raise ValueError('Install ffmpeg and ffprobe on this host for video previews.')
        else: raise ValueError('Unsupported media type.')
        remaining=256000
        for e,(sidefd,sideinfo) in zip(members[1:],opened[1:]):
            if remaining<=0: break
            is_json=os.path.splitext(e['name'])[1].lower()=='.json'
            if sideinfo.st_size>2*1024*1024: content='Preview exceeds 2 MiB.'
            else:
                with os.fdopen(os.dup(sidefd),'rb') as f:
                    try:
                        data=f.read(2*1024*1024+1)
                        if len(data)>2*1024*1024: content='Preview exceeds 2 MiB.'
                        elif is_json: content=json.dumps(json.loads(data),ensure_ascii=False,indent=2)[:24000]
                        elif b'\x00' in data: content='No text preview.'
                        else: content=data.decode('utf8')[:24000]
                    except (ValueError,UnicodeError): content='Invalid JSON.' if is_json else 'No text preview.'
            content=content[:remaining]; remaining-=len(content)
            companions.append(dict(name=e['name'],text=content))
            if is_json and sidecar is None: sidecar=content
        if any(fingerprint(os.fstat(fd))!=fingerprint(s) for fd,s in opened):
            raise ValueError('File changed while generating preview. Refresh and retry.')
        if image and len(image)>4*1024*1024: raise ValueError('Preview exceeds 4 MiB. Use Original.')
        # Bound arbitrary embedded text before encoding the response.
        while sum(len(v) for v in text.values())>256000: text.popitem()
        while sum(len(v) for v in meta.values())>256000: meta.popitem()
        return dict(fingerprint=token,image=base64.b64encode(image).decode() if image else None,
                    metadata=meta,text=text,sidecar=sidecar,companions=companions)
    finally:
        for fd,s in opened: os.close(fd)

try:
    q=json.loads(sys.stdin.buffer.read(8*1024*1024+1))
    root=check_path(q['root'])
    action=q['action']
    if action=='list': result=list_folder(root)
    elif action=='collection': result=collection(root)
    elif action in ('archive','restore'): result=mutate(q)
    elif action=='delete': result=delete(q)
    elif action=='deleteBatch': result=delete_batch(q)
    elif action=='preview': result=preview(q)
    elif action=='documentStat':
        paths=q.get('paths',[])
        if not 1<=len(paths)<=128: raise ValueError('Invalid document resources.')
        entries=[]
        for path in paths:
            path=check_path(path)
            if not path.startswith(root.rstrip('/')+'/'): raise ValueError('Resource outside folder.')
            try:
                fd,s=snapshot(path); os.close(fd); entries.append(entry(path,s))
            except FileNotFoundError: pass
        result=dict(entries=entries)
    elif action=='stat':
        for e in q['members']:
            fd,s=snapshot(e['path'],e); os.close(fd)
        result={}
    else: raise ValueError('Unsupported asset operation.')
    output=json.dumps(result,ensure_ascii=True)
    if len(output)>7*1024*1024: raise ValueError('Remote response exceeds its limit.')
    print(output)
except Exception as e:
    print(json.dumps(dict(error=str(e)[:2000])))
"""#
}
