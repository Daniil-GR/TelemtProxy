#!/usr/bin/env bash
# Patch MEKOPR Telemt WEB menu: keep WEB link visible until Enter.
# Safe to run repeatedly; never changes Telemt config, Nginx or systemd.
set -Eeuo pipefail
if [[ ${EUID} -ne 0 ]]; then
  echo 'Запусти от root: sudo bash fix-mekopr-web-link.sh' >&2
  exit 1
fi
python3 - <<'PY'
from pathlib import Path
import re, shutil, subprocess, sys
p = Path('/opt/mtpr-simple/proxys/telemt1.sh')
if not p.is_file():
    sys.exit('[ERROR] Меню MEKOPR не найдено: ' + str(p))
s = p.read_text(encoding='utf-8')
pattern = re.compile(r'(?m)^([ \t]*)s\|S\)\s*_web_show_link\s+"\$cfg"\s*\|\|\s*true\s*;;[ \t]*$')
found = list(pattern.finditer(s))
if len(found) != 1:
    if re.search(r'(?m)^[ \t]*s\|S\)[^\n]*_web_show_link[^\n]*(?:read -r|read -p)', s) or ('Нажмите Enter для возврата в меню' in s and re.search(r'(?m)^[ \t]*s\|S\)', s)):
        print('[OK] Пункт S уже исправлен.')
        sys.exit(0)
    sys.exit(f'[ERROR] Ожидалась одна строка меню s|S, найдено {len(found)}. Исходник MEKOPR изменился, безопасная автозамена не выполнена.')
m = found[0]
indent = m.group(1)
new_case = '\n'.join((
    indent + 's|S)',
    indent + '    _web_show_link "$cfg" || true',
    indent + '    printf "\\n"',
    indent + '    read -r -p "  Нажмите Enter для возврата в меню..." </dev/tty || true',
    indent + '    ;;',
))
out = s[:m.start()] + new_case + s[m.end():]
backup = p.with_name(p.name + '.bak-before-web-link-fix')
if not backup.exists():
    shutil.copy2(p, backup)
p.write_text(out, encoding='utf-8')
checked = subprocess.run(['bash', '-n', str(p)], capture_output=True, text=True)
if checked.returncode:
    shutil.copy2(backup, p)
    sys.exit('[ERROR] Проверка синтаксиса не пройдена. Исходный файл восстановлен:\n' + checked.stderr)
print('[OK] Пункт S исправлен. Ссылка останется на экране до Enter.')
print('[INFO] Резервная копия:', backup)
PY