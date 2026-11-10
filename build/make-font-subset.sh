#!/bin/bash
# make-font-subset.sh — 从构建机自带的 Noto Sans CJK 子集化出 PE 用的小字体。
# 整套 Noto CJK 有上百 MB，不能进 ISO；按 GB2312 字符集（一二级字库+符号区）
# + ASCII + 常用标点子集化后约 1-2 MB，fbterm 用它在 tty 上显示中文。
# 产物：/data/home/build/files/fonts/NotoSansSC-Subset.ttf（构建机本地文件，
# 不进 git；换机构建时跑一次本脚本重新生成）。
# 依赖：python3-fonttools（pyftsubset）。
set -euo pipefail
TTC=${1:-/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc}
OUT=${2:-/data/home/build/files/fonts/NotoSansSC-Subset.ttf}
mkdir -p "$(dirname "$OUT")"

python3 - <<'PY'
chars = set()
for hi in range(0xA1, 0xF8):
    for lo in range(0xA1, 0xFF):
        try:
            chars.add(bytes([hi, lo]).decode('gb2312'))
        except Exception:
            pass
chars |= set(chr(c) for c in range(0x20, 0x7F))
chars |= set('、。：；？！·—…「」『』（）《》〈〉％℃°±×÷§№☆★○●◎→←↑↓')
with open('/tmp/cjk-chars.txt', 'w', encoding='utf-8') as f:
    f.write(''.join(sorted(chars)))
print('charset:', len(chars), 'chars')
PY

IDX=$(python3 - "$TTC" <<'PY'
import sys
from fontTools.ttLib import TTCollection
ttc = TTCollection(sys.argv[1])
for i, f in enumerate(ttc.fonts):
    name = (f['name'].getDebugName(4) or '') + ' ' + (f['name'].getDebugName(1) or '')
    if 'SC' in name:
        print(i)
        break
PY
)
echo "Simplified-Chinese face index in TTC: $IDX"

python3 -m fontTools.subset "$TTC" --font-number="$IDX" --text-file=/tmp/cjk-chars.txt \
  --output-file="$OUT" --no-hinting --desubroutinize \
  --layout-features='' --name-IDs='*' --notdef-glyph --notdef-outline
ls -lh "$OUT"
