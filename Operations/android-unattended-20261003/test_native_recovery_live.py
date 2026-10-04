#!/usr/bin/env python3
from pathlib import Path
import json, re, subprocess, time, xml.etree.ElementTree as ET
BASE=Path.home()/'.remote-handset/android-unattended'
PHONES=['ZY22GDWXSZ','ZY22GHBP48','ZY22K2SXMK','31629594940010K','10AD6F2LSY0017B']
def adb(*args):
    r=subprocess.run(['/opt/homebrew/bin/adb',*args],capture_output=True,text=True,timeout=12)
    if r.returncode: raise RuntimeError(r.stderr or r.stdout)
    return r.stdout.strip()
for serial in PHONES:
    directory=BASE/serial
    assert adb('-s',serial,'shell','getprop','ro.serialno')==serial
    ip=re.search(r'\binet (\d+\.\d+\.\d+\.\d+)/',adb('-s',serial,'shell','ip','-o','-4','addr','show','dev','wlan0')).group(1)
    assert adb('-s',ip+':5555','shell','getprop','ro.serialno')==serial
    assert adb('-s',serial,'shell','settings','get','global','adb_wifi_enabled')=='1'
    adb('-s',serial,'shell','settings','put','global','adb_wifi_enabled','0')
    assert adb('-s',serial,'shell','settings','get','global','adb_wifi_enabled')=='0'
    subprocess.run(['/usr/bin/python3',str(directory/'guard.py')],check=True,timeout=55)
    deadline=time.monotonic()+30
    verified=None
    while time.monotonic()<deadline:
        mdns=adb('mdns','services')
        for line in mdns.splitlines():
            if 'adb-'+serial+'-' not in line or '_adb-tls-connect' not in line: continue
            port=re.search(r':(\d+)\s*$',line).group(1)
            endpoint=ip+':'+port
            try:
                adb('connect',endpoint)
                if adb('-s',endpoint,'shell','getprop','ro.serialno')==serial:
                    verified=endpoint
                    break
            except (RuntimeError,subprocess.TimeoutExpired):pass
        if verified and adb('-s',serial,'shell','settings','get','global','adb_wifi_enabled')=='1':break
        time.sleep(1)
    assert verified, (serial,'native TLS did not recover')
    assert adb('-s',serial,'shell','getprop','ro.serialno')==serial
    assert adb('-s',ip+':5555','shell','getprop','ro.serialno')==serial
    adb('-s',serial,'shell','uiautomator','dump','/data/local/tmp/wireless-setup.xml')
    root=ET.fromstring(adb('-s',serial,'shell','cat','/data/local/tmp/wireless-setup.xml'))
    prompts=[n.get('text','') for n in root.iter('node') if n.get('resource-id')=='android:id/alertTitle' and '无线调试' in n.get('text','')]
    assert not prompts, (serial,'unexpected network prompt')
    subprocess.run(['/usr/bin/python3',str(directory/'guard.py')],check=True,timeout=55)
    result={'serial':serial,'native_disable_then_guard_restore':'passed','tls_endpoint':verified,'usb':'verified','tcp':'verified','network_confirmation_prompt':False,'phone_rebooted':False,'at':time.time()}
    (directory/'native-recovery-test.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps(result,ensure_ascii=False),flush=True)
