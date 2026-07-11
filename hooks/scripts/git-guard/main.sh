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

# 対象操作の検出（旧 cchook 構成の command_contains と同じ部分一致基準）
ops=""
case "$cmd" in *"git rebase"* | *"pull --rebase"* | *"git pull -r"*) ops="$ops rebase" ;; esac
case "$cmd" in *"git reset"*) ops="$ops reset" ;; esac
case "$cmd" in *"git push"*) ops="$ops push" ;; esac
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
