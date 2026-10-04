#!/usr/bin/env python3
import ast, hashlib, json, os, plistlib, re, shutil, subprocess, time
from pathlib import Path
BASE=Path.home()/'.remote-handset'
FLEET=BASE/'android-unattended'
TARGETS={'ZY22HN3ZS4': BASE/'backup3-unattended', 'ZY22F68DH8': BASE/'white-motorola-unattended',
 **{s:FLEET/s for s in ['ZY22GHBP48','ZY22K2SXMK','31629594940010K','ZY22GDWXSZ','10AD6F2LSY0017B']}}
TEMPLATE=(FLEET/'guard-template.py').read_text()
assert 'SYSTEM_TRUST_GATE = False' in TEMPLATE
assert '\"enabled\": True' in TEMPLATE
for serial,directory in TARGETS.items():
    result=subprocess.run(['/opt/homebrew/bin/adb','-s',serial,'shell','getprop ro.serialno; getprop service.adb.tcp.port; ip -o -4 addr show dev wlan0'],capture_output=True,text=True,check=True,timeout=12).stdout
    rows=result.splitlines()
    assert rows[0]==serial and rows[1]=='5555', (serial,'USB/TCP precondition')
    ip=re.search(r'\binet (\d+\.\d+\.\d+\.\d+)/',result).group(1)
    record=json.loads((directory/'installation.json').read_text())
    trusted=record.get('trusted_bssids') or [record.get('trusted_bssid','66:20:e3:1d:e8:ce')]
    assert trusted and all(re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}',b) for b in trusted)
    source=re.sub(r'^SERIAL = .*$', 'SERIAL = '+repr(serial), TEMPLATE, flags=re.M)
    source=re.sub(r'^INITIAL = .*$', 'INITIAL = '+repr(ip+':5555'), source, flags=re.M)
    source=re.sub(r'^TRUSTED_BSSIDS = .*$', 'TRUSTED_BSSIDS = '+repr(set(trusted)), source, flags=re.M)
    if serial in ['31629594940010K','10AD6F2LSY0017B']:
        source=source.replace('SYSTEM_TRUST_GATE = False','SYSTEM_TRUST_GATE = True')
    ast.parse(source)
    target=directory/'guard.py'
    backup=directory/'guard.before-seven.py'
    if target.exists() and not backup.exists(): shutil.copy2(target,backup)
    temporary=directory/'guard.installing.py'
    temporary.write_text(source);os.chmod(temporary,0o700);os.replace(temporary,target)
    record.update(host_guard_installed=True, fleet_guard_sha256=hashlib.sha256(source.encode()).hexdigest(), fleet_enhanced_at=time.time(), system_trust_gate=serial in ['31629594940010K','10AD6F2LSY0017B'])
    (directory/'installation.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
    for attempt in range(5):
        subprocess.run(['/usr/bin/python3',str(target)],check=True,timeout=55)
        status=json.loads((directory/'status.json').read_text())
        if status.get('serial')==serial and status.get('enabled') and status.get('usb')=='verified' and status.get('wifi')=='verified': break
        time.sleep(1)
    else: raise RuntimeError((serial,status))
    print(json.dumps({'serial':serial,'usb':status['usb'],'wifi':status['wifi'],'live':status['live_verified_endpoints']},ensure_ascii=False),flush=True)
