#!/usr/bin/env bash
# git-guard/main.sh — PreToolUse hook（matcher: Bash）。
# git rebase / git reset を「対応スキルの arm marker がある時だけ」通し、
# raw の force push を gh-push スキル経由へ誘導する。
#
# marker はスキルの arm スクリプトが置く:
#   rebase: rebase-flow の scripts/rebase-backup.sh → .git/rebase-flow.armed
#   reset:  reset-flow  の scripts/reset-arm.sh    → .git/reset-flow.armed
# いずれも「計画提示 → ユーザー承認 → backup/safety branch 作成」を通過した
# 証跡であり、これが無い実行は履歴書き換えの野良実行なのでブロックする。
#
# Claude Code の PreToolUse hook として stdin で JSON を受け取り、stdout の JSON が
# そのまま応答になる。旧 cchook 構成では対象コマンドの絞り込み（command_contains）を
# cchook 側の条件が担っていたが、本スクリプトは matcher: Bash で全コマンドを受け、
# 対象操作（rebase / reset / push）の検出も自前で行う。対象外コマンドは沈黙（exit 0）。
# 対象コマンドの判定:
#   pass = permissionDecision: ask  → ユーザー確認へ（allow は権限バイパスに
#                                      なるため使わない。settings の ask とも整合）
#   deny = permissionDecision: deny → 実行ブロック（理由を Claude が読む）
# 複合コマンドで複数操作が混在する場合は deny を最優先で採用する。
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cmd" ] || exit 0

# 対象操作の検出。コマンド文字列全体への部分一致だと、報告コマンドの引数・検索
# パターン・heredoc 本文に載ったリテラルにまで反応する（実行されないテキストを
# 履歴書き換えと誤認する）。そのためコマンドを引用符・heredoc を解した上で
# segment（; | & 改行 区切り）へ分解し、各 segment の先頭語と git の
# サブコマンド名で判定する。
# 引用符は外して中身を残すので、sh -c "…" の payload も語として見える。
found_rebase=0
found_reset=0
found_push=0

# 語の中の部分一致で検出する（sh -c / eval / xargs の payload 用。裁定により
# これらの引数内だけは従来の部分一致基準を残す）。
scan_payload() { # <text...>
    local text="$*"
    case "$text" in *"git rebase"* | *"pull --rebase"* | *"git pull -r"*) found_rebase=1 ;; esac
    case "$text" in *"git reset"*) found_reset=1 ;; esac
    case "$text" in *"git push"*) found_push=1 ;; esac
}

# 1 segment の語列を分類する。
classify_segment() {
    local -a w=("$@")
    local i=0 sub="" arg
    # 先頭の環境変数代入は読み飛ばす（FOO=bar git reset …）
    while [ "$i" -lt "${#w[@]}" ]; do
        case "${w[i]}" in
            [A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    [ "$i" -lt "${#w[@]}" ] || return 0

    case "${w[i]}" in
        git)
            i=$((i + 1))
            # global option を読み飛ばす。値を次の語に取る形式はまとめて捨てる
            while [ "$i" -lt "${#w[@]}" ]; do
                case "${w[i]}" in
                    -C | -c | --git-dir | --work-tree | --namespace) i=$((i + 2)) ;;
                    -*) i=$((i + 1)) ;;
                    *) break ;;
                esac
            done
            [ "$i" -lt "${#w[@]}" ] || return 0
            sub="${w[i]}"
            case "$sub" in
                rebase) found_rebase=1 ;;
                reset) found_reset=1 ;;
                push) found_push=1 ;;
                pull)
                    for arg in "${w[@]:i}"; do
                        case "$arg" in
                            --rebase | --rebase=* | -r) found_rebase=1 ;;
                        esac
                    done
                    ;;
            esac
            ;;
        sh | bash | zsh | dash)
            # -c より前に operand が来たらスクリプト実行なので payload は見ない
            i=$((i + 1))
            while [ "$i" -lt "${#w[@]}" ]; do
                case "${w[i]}" in
                    --)
                        i=$((i + 1))
                        break
                        ;;
                    -*c*)
                        i=$((i + 1))
                        scan_payload "${w[@]:i}"
                        return 0
                        ;;
                    -*) i=$((i + 1)) ;;
                    *) break ;;
                esac
            done
            ;;
        eval | xargs) scan_payload "${w[@]:i+1}" ;;
    esac
}

# $cmd を 1 文字ずつ走査して引用符・heredoc を解し、segment 単位で classify する。
split_and_classify() {
    local n=${#cmd} i=0 ch word="" quote="" delim="" strip_tabs=0 line
    local -a words=()
    finish_word() { [ -n "$word" ] && {
        words+=("$word")
        word=""
    } || true; }
    finish_segment() {
        finish_word
        [ "${#words[@]}" -gt 0 ] && classify_segment "${words[@]}"
        words=()
    }
    while [ "$i" -lt "$n" ]; do
        ch="${cmd:i:1}"
        i=$((i + 1))
        if [ "$quote" = "'" ]; then
            [ "$ch" = "'" ] && quote="" || word+="$ch"
            continue
        fi
        if [ "$quote" = '"' ]; then
            if [ "$ch" = '"' ]; then
                quote=""
            elif [ "$ch" = '\' ] && [ "$i" -lt "$n" ]; then
                word+="${cmd:i:1}"
                i=$((i + 1))
            else
                word+="$ch"
            fi
            continue
        fi
        case "$ch" in
            "'" | '"') quote="$ch" ;;
            '\')
                if [ "$i" -lt "$n" ]; then
                    [ "${cmd:i:1}" = $'\n' ] || word+="${cmd:i:1}"
                    i=$((i + 1))
                fi
                ;;
            ' ' | $'\t') finish_word ;;
            ';' | '|' | '&') finish_segment ;;
            $'\n')
                finish_segment
                # 直前に heredoc が宣言されていれば、本文を delimiter まで捨てる
                if [ -n "$delim" ]; then
                    while [ "$i" -lt "$n" ]; do
                        line="${cmd:i}"
                        line="${line%%$'\n'*}"
                        i=$((i + ${#line}))
                        [ "$i" -lt "$n" ] && i=$((i + 1))
                        [ "$strip_tabs" = 1 ] && line="${line#"${line%%[!$'\t']*}"}"
                        [ "$line" = "$delim" ] && break
                    done
                    delim=""
                    strip_tabs=0
                fi
                ;;
            '<')
                if [ "${cmd:i:1}" = '<' ] && [ "${cmd:i+1:1}" = '<' ]; then
                    # <<< は here-string（データ）。演算子だけ読み飛ばして
                    # heredoc として扱わない（後続の segment を飲み込まないため）
                    i=$((i + 2))
                elif [ "${cmd:i:1}" = '<' ]; then
                    i=$((i + 1))
                    strip_tabs=0
                    if [ "${cmd:i:1}" = '-' ]; then
                        strip_tabs=1
                        i=$((i + 1))
                    fi
                    while [ "$i" -lt "$n" ] && { [ "${cmd:i:1}" = ' ' ] || [ "${cmd:i:1}" = $'\t' ]; }; do
                        i=$((i + 1))
                    done
                    delim=""
                    while [ "$i" -lt "$n" ]; do
                        ch="${cmd:i:1}"
                        case "$ch" in
                            ' ' | $'\t' | $'\n' | ';' | '|' | '&' | '<' | '>') break ;;
                            "'" | '"') ;;
                            *) delim+="$ch" ;;
                        esac
                        i=$((i + 1))
                    done
                fi
                ;;
            *) word+="$ch" ;;
        esac
    done
    finish_segment
}

split_and_classify

# ops の順序は従来どおり rebase → reset → push で固定する（PASS_REASON の採用順と
# 複合コマンドの挙動を変えないため）
ops=""
[ "$found_rebase" = 1 ] && ops="$ops rebase"
[ "$found_reset" = 1 ] && ops="$ops reset"
[ "$found_push" = 1 ] && ops="$ops push"
[ -n "$ops" ] || exit 0

DENY_REASON=""
PASS_REASON=""
deny() { [ -n "$DENY_REASON" ] || DENY_REASON="$1"; }
pass() { [ -n "$PASS_REASON" ] || PASS_REASON="$1"; }

# marker はコマンドが実行される repo（= セッション cwd の repo）側で探す。
# 複合コマンドで別 repo へ cd するケースは marker が見つからず deny に倒れる（安全側）。
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    cd "$cwd" 2>/dev/null || true
fi

# push: raw の force push（--force / --force-with-lease / -f / +refspec）を拒否し、
# gh-push スキル（保護ブランチ拒否・明示 lease を script が強制）へ誘導する。
# 通常 push は ask → settings の ask と同じくユーザー確認に落ちる。
guard_push() {
    if printf '%s' "$cmd" | grep -Eq -- 'push[^|;&]*(--force|[[:space:]]-f([[:space:]]|$)|[[:space:]]\+[[:graph:]])'; then
        deny "🚫 raw の force push は禁止。gh-push スキル（gh-push.sh push <branch> --force [--expect=<sha>]）経由でのみ実行可 — 保護ブランチ拒否と明示 lease が強制される。rebase 後の push は rebase-flow §7 の手順に従うこと。"
        return 0
    fi
    pass "通常 push（force なし）— ユーザー確認へ"
}

guard_flow() { # <rebase|reset>
    local op="$1" skill marker armed_at now abort_note
    skill="${op}-flow"

    # 脱出経路は常時通す: --abort は「開始前に戻す」操作で、塞ぐと事故が悪化する
    if [ "$op" = "rebase" ]; then
        case "$cmd" in
            *"rebase --abort"*)
                pass "脱出経路（git rebase --abort）— ユーザー確認へ"
                return 0
                ;;
        esac
    fi

    if ! marker=$(git rev-parse --git-path "${op}-flow.armed" 2>/dev/null); then
        pass "git repo 外（git 自体が失敗するはず）— ユーザー確認へ"
        return 0
    fi

    if [ ! -f "$marker" ]; then
        abort_note=""
        [ "$op" = "rebase" ] && abort_note="git rebase --abort のみ常時許可。"
        deny "🚫 git ${op} は ${skill} スキル経由でのみ実行可。${skill} スキルを起動し、計画提示 → ユーザー承認 → arm スクリプト（backup 作成 + 解錠）の後に再実行すること。${abort_note}"
        return 0
    fi

    # TTL 30 分。期限切れ marker は解錠状態の放置なので消す
    armed_at=$(cat "$marker" 2>/dev/null || echo 0)
    case "$armed_at" in
        *[!0-9]*) armed_at=0 ;;
    esac
    now=$(date +%s)
    if [ $((now - armed_at)) -gt 1800 ]; then
        rm -f "$marker"
        deny "🚫 ${skill} の解錠 marker が期限切れ（30 分）。${skill} のワークフロー（計画 → 承認 → arm）をやり直すこと。"
        return 0
    fi

    pass "${skill} arm 済み（marker 有効）— ユーザー確認へ"
}

for op in $ops; do
    case "$op" in
        push) guard_push ;;
        rebase | reset) guard_flow "$op" ;;
    esac
done

if [ -n "$DENY_REASON" ]; then
    jq -cn --arg r "$DENY_REASON" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
else
    jq -cn --arg r "$PASS_REASON" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
fi
