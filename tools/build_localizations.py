"""Build checked-in Apple strings tables from reviewed translations.

Only generation needs opencc-python-reimplemented==0.1.7. It is not shipped or
used by the app. Hong Kong terminology and Cantonese prompts override conversion.
"""
import json
from pathlib import Path
import re
from opencc import OpenCC

ROOT = Path(__file__).resolve().parents[1]

def pairs(path):
    values = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'): continue
        key, value = line.split('|', 1)
        if key in values: raise ValueError('Duplicate key: ' + key)
        values[key] = value
    return values

def decode(value):
    return value.replace('\\n', '\n').replace('\\"', '"').replace('\\u0020', ' ')

def build():
    english = pairs(ROOT / 'Localization/english.tsv')
    overrides = pairs(ROOT / 'Localization/hong-kong-overrides.tsv')
    converter = OpenCC('s2hk')
    hong_kong = {}
    for key, value in english.items():
        if re.search('[\u3400-\u9fff]', value): raise ValueError('Untranslated English: ' + key)
        translated = converter.convert(key)
        for old, new in [('照片', '相片'), ('視頻', '影片'), ('文件', '檔案'), ('原件', '原檔'), ('設置', '設定'), ('賬號', '帳戶'), ('帳號', '帳戶'), ('上傳', '上載'), ('默認', '預設'), ('蜂窩', '流動數據'), ('後台', '背景'), ('谷歌相冊', 'Google 相簿'), ('Google 相冊', 'Google 相簿'), ('任務', '工作'), ('核驗', '驗證')]:
            translated = translated.replace(old, new)
        for old, new in [('登錄', '登入'), ('粘貼', '貼上'), ('響應', '回應'), ('服務端', '伺服器'), ('服務器', '伺服器')]:
            translated = translated.replace(old, new)
        hong_kong[key] = overrides.get(key, translated)
    tables = {'zh-Hans': {key: key for key in english}, 'en': english, 'zh-Hant-HK': hong_kong, 'yue-Hant-HK': hong_kong}
    (ROOT / 'Resources/MessageKeys.json').write_text(json.dumps([decode(key) for key in english], ensure_ascii=False), encoding='utf-8')
    for language, values in tables.items():
        folder = ROOT / 'Resources' / (language + '.lproj'); folder.mkdir(exist_ok=True)
        output = []
        for key, value in sorted(values.items()):
            if sorted(re.findall(r'\{\d+\}', key)) != sorted(re.findall(r'\{\d+\}', value)):
                raise ValueError('Placeholder mismatch: ' + key)
            output.append(json.dumps(decode(key), ensure_ascii=False) + ' = ' + json.dumps(decode(value), ensure_ascii=False) + ';')
        (folder / 'Localizable.strings').write_text('\n'.join(output) + '\n', encoding='utf-8')
        privacy = {'zh-Hans': '浏览并备份你允许访问的照片与视频。', 'en': 'Browse and back up photos and videos you allow.', 'zh-Hant-HK': '瀏覽同備份你允許取用嘅相片同影片。', 'yue-Hant-HK': '瀏覽同備份你允許取用嘅相片同影片。'}
        camera = {
            'zh-Hans': '扫描二维码以添加代理订阅，或连接同一网络上的电脑。',
            'en': 'Scan QR codes to add proxy subscriptions or connect to a computer on the same network.',
            'zh-Hant-HK': '掃描二維碼加入代理訂閱，或連接同一網絡上的電腦。',
            'yue-Hant-HK': '掃描二維碼加入代理訂閱，或連接同一網絡上的電腦。',
        }
        local_network = {
            'zh-Hans': '用于连接同一局域网中正在运行的 PicHarbor 电脑并直接传输照片。不会通过互联网转发。',
            'en': 'Connects to a PicHarbor computer on the same local network to send photos directly. Nothing is relayed over the internet.',
            'zh-Hant-HK': '用於連接同一區域網絡上正在運行的 PicHarbor 電腦，並直接傳送相片。不會經互聯網轉發。',
            'yue-Hant-HK': '用於連接同一區域網絡上正在運行的 PicHarbor 電腦，並直接傳送相片。不會經互聯網轉發。',
        }
        (folder / 'InfoPlist.strings').write_text('"NSPhotoLibraryUsageDescription" = ' + json.dumps(privacy[language], ensure_ascii=False) + ';\n' +
            '"NSCameraUsageDescription" = ' + json.dumps(camera[language], ensure_ascii=False) + ';\n' +
            '"NSLocalNetworkUsageDescription" = ' + json.dumps(local_network[language], ensure_ascii=False) + ';\n', encoding='utf-8')
    print('Built', len(english), 'strings for', ', '.join(tables))

if __name__ == '__main__': build()
