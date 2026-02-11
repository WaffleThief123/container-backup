#!/usr/bin/env bash
# encrypt.sh - age encryption/decryption wrappers

# Encrypt a file with age.
# Usage: encrypt_file /path/to/archive.tar.zst /path/to/output.tar.zst.age
# Returns 0 on success, 1 on failure. Prints output path on success.
encrypt_file() {
    local input_file="$1"
    local output_file="$2"

    if [[ -z "$AGE_RECIPIENT" ]]; then
        log_error "AGE_RECIPIENT not set, cannot encrypt"
        return 1
    fi

    if ! command -v age &>/dev/null; then
        log_error "age is not installed"
        return 1
    fi

    log_info "Encrypting: $(basename "$input_file")"

    if age -r "$AGE_RECIPIENT" -o "$output_file" "$input_file" 2>/tmp/age_err; then
        local size
        size="$(du -h "$output_file" | cut -f1)"
        log_info "  Encrypted: $size"
        echo "$output_file"
        return 0
    else
        log_error "  Encryption failed: $(cat /tmp/age_err)"
        rm -f "$output_file"
        return 1
    fi
}

# Decrypt a file with age.
# Usage: decrypt_file /path/to/archive.tar.zst.age /path/to/archive.tar.zst
decrypt_file() {
    local input_file="$1"
    local output_file="$2"

    if [[ -z "$AGE_KEY_FILE" ]]; then
        log_error "AGE_KEY_FILE not set, cannot decrypt"
        return 1
    fi

    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        log_error "Age key file not found: $AGE_KEY_FILE"
        return 1
    fi

    if ! command -v age &>/dev/null; then
        log_error "age is not installed"
        return 1
    fi

    log_info "Decrypting: $(basename "$input_file")"

    if age -d -i "$AGE_KEY_FILE" -o "$output_file" "$input_file" 2>/tmp/age_err; then
        log_info "  Decrypted: $(du -h "$output_file" | cut -f1)"
        echo "$output_file"
        return 0
    else
        log_error "  Decryption failed: $(cat /tmp/age_err)"
        rm -f "$output_file"
        return 1
    fi
}
