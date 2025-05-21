#!/bin/bash

# Проверка прав администратора
if [ "$(id -u)" -ne 0 ]; then
    echo "✖ Ошибка: Скрипт требует прав администратора. Запустите с sudo." >&2
    exit 1
fi

# Функция для загрузки файлов с GitHub
download_from_github() {
    local repo_owner="asualexr"
    local repo_name="macos-pkgs"
    local file_path="$1"
    local output_path="$2"
    
    echo "Загружаем $file_path с GitHub..."
    if ! curl -sL "https://github.com/$repo_owner/$repo_name/raw/main/$file_path" -o "$output_path"; then
        echo "Ошибка загрузки $file_path" >&2
        return 1
    fi
    
    if grep -q "<!DOCTYPE html>" "$output_path"; then
        echo "Файл $file_path не найден в репозитории" >&2
        rm -f "$output_path"
        return 1
    fi
    
    echo "Файл успешно загружен: $output_path"
    return 0
}



CISCO_HASH_ENC="U2FsdGVkX1/eWiH327AV7pZqKJLrn3oeaS/PDvSHwVmE10HFGtjjnrKABnZnWfE6mb9/vaRY9tz+krBYaPlGncCqOljTJYl3yyDqY56fCvkTVcme1IqjwstVfGjqH3K/"
OFFICE_HASH_ENC="U2FsdGVkX188XLwElW8WmrHwZQBzlBB01IbEMAxt3Y28pIjKDvJ9iyhXpbEyJh3BKefKkr4WbJdt8BoKzLyDsVM8UUPYi0TWlhP1OBxpQa+62boSf7e5itW9WHs+yZMp"

# ==============================================
# 1. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
# ==============================================

echo "=== 1. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ==="

# Запрос имени пользователя
while true; do
    read -p "Введите имя нового пользователя: " username
    if [[ "$username" =~ ^[a-z][-a-z0-9_]*$ ]]; then
        break
    else
        echo "✖ Неверное имя. Используйте только строчные латинские буквы, цифры, дефисы и подчёркивания." >&2
    fi
done

# Проверка существования пользователя
if id "$username" &>/dev/null; then
    echo "✖ Ошибка: Пользователь '$username' уже существует." >&2
    exit 1
fi

# Генерация UniqueID
last_id=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
unique_id=$((last_id + 1))

# Создание пользователя
echo "ℹ Создаю пользователя $username с ID $unique_id..."
dscl . -create /Users/$username
dscl . -create /Users/$username UserShell "/bin/zsh"
dscl . -create /Users/$username RealName "$username"
dscl . -create /Users/$username UniqueID "$unique_id"
dscl . -create /Users/$username PrimaryGroupID 80
dscl . -create /Users/$username NFSHomeDirectory "/Users/$username"

# Создание домашней директории
mkdir -p "/Users/$username"
chown "$username:staff" "/Users/$username"

# Установка пароля
while true; do
    echo "Введите пароль для пользователя $username:"
    if passwd "$username"; then
        break
    else
        echo "✖ Ошибка при установке пароля, попробуйте ещё раз." >&2
    fi
done

# Добавление в группу админов
dscl . -append /Groups/admin GroupMembership "$username"

# Переименование компьютера
echo "ℹ Переименовываю компьютер в '$username'..."
scutil --set ComputerName "$username"
scutil --set LocalHostName "$username"
scutil --set HostName "$username"
dscacheutil -flushcache

# ==============================================
# 2. УСТАНОВКА XCODE И HOMEBREW
# ==============================================

echo -e "\n=== 2. УСТАНОВКА XCODE И HOMEBREW ==="

# Установка Xcode Command Line Tools
echo "ℹ Устанавливаю Xcode Command Line Tools..."
xcode-select --install 2>/dev/null
sleep 1
osascript <<EOD
  tell application "System Events"
    tell process "Install Command Line Developer Tools"
      keystroke return
      click button "Agree" of window "License Agreement"
    end tell
  end tell
EOD

until xcode-select -p &>/dev/null; do
    sleep 5
done

# Установка Homebrew
echo "ℹ Устанавливаю Homebrew..."
su - $username -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# Настройка окружения Brew
brew_path="/opt/homebrew/bin/brew"
[ -f "$brew_path" ] || brew_path="/usr/local/bin/brew"
if [ -f "$brew_path" ]; then
    echo "eval \"\$($brew_path shellenv)\"" >> "/Users/$username/.zprofile"
    chown "$username:staff" "/Users/$username/.zprofile"
    eval "$($brew_path shellenv)"
else
    echo "✖ Ошибка: Homebrew не установлен правильно" >&2
    exit 1
fi

# ==============================================
# 3. УСТАНОВКА ОСНОВНЫХ ПРИЛОЖЕНИЙ
# ==============================================

echo -e "\n=== 3. УСТАНОВКА ОСНОВНЫХ ПРИЛОЖЕНИЙ ==="

echo "ℹ Устанавливаю приложения (Yandex, Telegram, KeePassXC, Microsoft Office)..."
su - $username -c 'brew install --cask microsoft-office keepassxc yandex telegram yubico-authenticator anydesk'

# ==============================================
# 4. УСТАНОВКА CISCO SECURE CLIENT (VPN ONLY)
# ==============================================

echo -e "\n=== 4. УСТАНОВКА CISCO SECURE CLIENT (VPN ONLY) ==="

CISCO_TMP="/tmp/CiscoSecureClient.pkg"
TMP_DIR="/tmp/CiscoUnpacked"
OUTPUT_PKG="/tmp/CiscoVPNOnly.pkg"
VPN_PKG_NAME="AnyConnectVPN.pkg"

# Загрузка пакета с GitHub
if ! download_from_github "CiscoSecureClient.pkg" "$CISCO_TMP"; then
    echo "Пропускаем установку Cisco Secure Client"
    exit 0
fi

# Функция для расшифровки данных
decrypt_hash() {
    local encrypted_data="$1"
    # Запрашиваем пароль только если он еще не был введен
    if [ -z "$DECRYPT_PASSWORD" ]; then
        echo -n "Введите пароль для дешифровки контрольных сумм: "
        read -s DECRYPT_PASSWORD
        echo
    fi
    
    # Дешифруем и выводим хеш без переноса строки
    echo "${encrypted_data}" | openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt -a -pass pass:"$DECRYPT_PASSWORD" 2>/dev/null | tr -d '\n'
}

# Проверка контрольной суммы
echo "Проверяем контрольную сумму пакета..."

# Сначала запрашиваем пароль
echo -n "Введите пароль для дешифровки контрольных сумм: "
read -s DECRYPT_PASSWORD
echo

# Затем получаем и выводим ожидаемый хеш
CISCO_HASH=$(echo "$CISCO_HASH_ENC" | openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt -a -pass pass:"$DECRYPT_PASSWORD" 2>/dev/null | tr -d '\n')
if [ -z "$CISCO_HASH" ]; then
    echo "✖ Ошибка: Неверный пароль или поврежденные данные" >&2
    rm -f "$CISCO_TMP"
    exit 1
fi



# Вычисляем хеш загруженного файла
CALCULATED_CISCO_HASH=$(shasum -a 256 "$CISCO_TMP" | awk '{print $1}')


# Сравниваем хеши
if [ "$CALCULATED_CISCO_HASH" != "$CISCO_HASH" ]; then
    echo "✖ Ошибка: Контрольные суммы не совпадают!" >&2
    rm -f "$CISCO_TMP"
    exit 1
else
    echo "✓ Контрольные суммы совпадают"
fi


# Распаковка оригинального пакета
echo "Распаковываем Cisco Secure Client..."
rm -rf "$TMP_DIR" 2>/dev/null
if ! pkgutil --expand "$CISCO_TMP" "$TMP_DIR"; then
    echo "✖ Ошибка: не удалось распаковать .pkg!" >&2
    rm -f "$CISCO_TMP"
    exit 1
fi

# Удаление ненужных компонентов
echo "Удаляем ненужные модули (оставляем только VPN)..."
cd "$TMP_DIR" || exit 1
find . -type d \( -name "AnyConnect*" ! -name "*$VPN_PKG_NAME*" \) -exec rm -rf {} + 2>/dev/null
find . -type d \( -name "Cisco*" ! -name "*VPN*" \) -exec rm -rf {} + 2>/dev/null

# Сборка нового пакета только с VPN
echo "Собираем новый .pkg только с VPN..."
if ! pkgutil --flatten "$TMP_DIR" "$OUTPUT_PKG"; then
    echo "✖ Ошибка: не удалось создать .pkg!" >&2
    rm -rf "$TMP_DIR" "$CISCO_TMP"
    exit 1
fi

# Установка с учетом архитектуры
echo "⚙ Устанавливаем Cisco VPN..."
INSTALL_CMD=()
if [[ $(uname -m) == "arm64" ]]; then
    echo "Обнаружен Apple Silicon (M1/M2), используем Rosetta 2..."
    INSTALL_CMD=(arch -x86_64 /usr/sbin/installer)
else
    INSTALL_CMD=(/usr/sbin/installer)
fi

if ! "${INSTALL_CMD[@]}" -pkg "$OUTPUT_PKG" -target /; then
    echo "✖ Ошибка: установка не удалась!" >&2
    rm -rf "$TMP_DIR" "$OUTPUT_PKG" "$CISCO_TMP"
    exit 1
fi

# Проверка установки
if [ -x "/opt/cisco/secureclient/bin/vpn" ]; then
    echo "✓ Cisco Secure Client (VPN Only) успешно установлен"
else
    echo "⚠ Предупреждение: VPN-клиент установлен, но бинарник не найден" >&2
fi

# Очистка временных файлов
rm -rf "$TMP_DIR" "$OUTPUT_PKG" "$CISCO_TMP"

# ==============================================
# 5. УСТАНОВКА MICROSOFT OFFICE SERIALIZER
# ==============================================

echo -e "\n=== 5. УСТАНОВКА MICROSOFT OFFICE SERIALIZER ==="

OFFICE_SERIALIZER_TMP="/tmp/Microsoft_Office_LTSC_2024_VL_Serializer.pkg"

# Загрузка сериализатора с GitHub
if ! download_from_github "Microsoft_Office_LTSC_2024_VL_Serializer.pkg" "$OFFICE_SERIALIZER_TMP"; then
    echo "Пропускаем установку Office Serializer"
else
    # Проверка контрольной суммы
    echo "Проверяем контрольную сумму сериализатора..."
    OFFICE_HASH=$(decrypt_hash "$OFFICE_HASH_ENC")
    if [ -z "$OFFICE_HASH" ]; then
        echo "✖ Ошибка: Неверный пароль или поврежденные данные" >&2
        rm -f "$OFFICE_SERIALIZER_TMP"
        exit 1
    fi

    CALCULATED_OFFICE_HASH=$(shasum -a 256 "$OFFICE_SERIALIZER_TMP" | awk '{print $1}')
    
    if [ "$CALCULATED_OFFICE_HASH" != "$OFFICE_HASH" ]; then
        echo "✖ Ошибка: Контрольные суммы не совпадают!" >&2
        echo "  Ожидалось: $OFFICE_HASH" >&2
        echo "  Получено:  $CALCULATED_OFFICE_HASH" >&2
        rm -f "$OFFICE_SERIALIZER_TMP"
        exit 1
    fi
    
    # Установка
    echo "Устанавливаем Microsoft Office LTSC 2024 Serializer..."
    if installer -pkg "$OFFICE_SERIALIZER_TMP" -target /; then
        echo "✓ Serializer успешно установлен"
    else
        echo "✖ Ошибка установки Serializer" >&2
        exit 1
    fi
    
    rm -f "$OFFICE_SERIALIZER_TMP"
fi

# ==============================================
# ЗАВЕРШЕНИЕ
# ==============================================

echo -e "\n=== НАСТРОЙКА ЗАВЕРШЕНА ==="
echo "Пользователь $username успешно создан и настроен!"
echo "Установлены все необходимые приложения."
