#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_PANEL="$ROOT_DIR/Sources/ClipVault/Views/AIActionPanel.swift"
CONTENT_VIEW="$ROOT_DIR/Sources/ClipVault/Views/ContentView.swift"

fail() {
  echo "$1" >&2
  return 1
}

require_contains() {
  local source="$1"
  local marker="$2"
  local failure_message="$3"
  grep -Fq -- "$marker" <<<"$source" || fail "$failure_message"
}

require_absent() {
  local source="$1"
  local marker="$2"
  local failure_message="$3"
  ! grep -Fq -- "$marker" <<<"$source" || fail "$failure_message"
}

check_unified_workspace_policy() {
  local source="$1"
  local content_source="$2"
  local command_bar ask_field inline_result

  command_bar="$(sed -n '/struct AICommandBar:/,/struct InlineAIResultView:/p' <<<"$source" | sed '$d')"
  ask_field="$(sed -n '/private var askField:/,/private var contextIndicator:/p' <<<"$command_bar" | sed '$d')"
  inline_result="$(sed -n '/struct InlineAIResultView:/,$p' <<<"$source")"

  require_contains "$command_bar" '.background(.bar)' 'unified AI command bar must use the stable bar material' || return 1
  require_contains "$command_bar" '.buttonStyle(.plain)' 'unified AI actions must use plain button style' || return 1
  require_contains "$command_bar" '.clipVaultGlassSurface(' 'unified AI actions must use stable material surfaces' || return 1
  require_absent "$command_bar" '.clipVaultGlassButtonStyle' 'unified AI command bar must not use native glass button styles' || return 1
  require_absent "$command_bar" '.glassEffect(' 'unified AI command bar must not use native glass effects' || return 1

  require_contains "$ask_field" '.buttonStyle(.plain)' 'unified Ask control must use plain button style' || return 1
  require_contains "$ask_field" '.clipVaultGlassSurface(' 'unified Ask control must use the stable material surface' || return 1
  require_absent "$ask_field" '.clipVaultGlassButtonStyle' 'unified Ask control must remain native-glass-free' || return 1

  require_contains "$inline_result" '.clipVaultGlassSurface(' 'inline AI result must use a bounded material surface' || return 1
  require_absent "$inline_result" 'ScrollView {' 'inline AI result must rely on the single workspace scroll' || return 1

  require_absent "$source" 'AIActionPanelPlacement' 'legacy AI placement variants must be removed' || return 1
  require_absent "$source" 'AIWorkspaceShelf' 'legacy AI shelf must be removed' || return 1
  require_absent "$content_source" 'VSplitView' 'unified detail workspace must not use VSplitView' || return 1
  require_absent "$content_source" 'aiWorkspaceExpanded' 'legacy persisted AI expansion state must be removed' || return 1
}

mutate_ask_with_native_glass() {
  local source="$1"
  awk '
    /private var askField:/ { in_ask = 1 }
    in_ask && /\.buttonStyle\(\.plain\)/ && !injected {
      print
      print "            .clipVaultGlassButtonStyle()"
      injected = 1
      next
    }
    { print }
    /private var contextIndicator:/ { in_ask = 0 }
    END { if (!injected) exit 2 }
  ' <<<"$source"
}

mutate_result_with_nested_scroll() {
  local source="$1"
  awk '
    /private var ordinaryResult:/ && !injected {
      print
      print "        ScrollView {"
      injected = 1
      next
    }
    { print }
    END { if (!injected) exit 2 }
  ' <<<"$source"
}

SOURCE="$(<"$AI_PANEL")"
CONTENT_SOURCE="$(<"$CONTENT_VIEW")"
NATIVE_GLASS_FIXTURE="$(mutate_ask_with_native_glass "$SOURCE")"
NESTED_SCROLL_FIXTURE="$(mutate_result_with_nested_scroll "$SOURCE")"

if check_unified_workspace_policy "$NATIVE_GLASS_FIXTURE" "$CONTENT_SOURCE" >/dev/null 2>&1; then
  fail 'unified workspace policy false-pass: native-glass Ask mutation was accepted'
  exit 1
fi

if check_unified_workspace_policy "$NESTED_SCROLL_FIXTURE" "$CONTENT_SOURCE" >/dev/null 2>&1; then
  fail 'unified workspace policy false-pass: nested AI result scroll mutation was accepted'
  exit 1
fi

check_unified_workspace_policy "$SOURCE" "$CONTENT_SOURCE"
echo "Unified AI workspace policy passed (production + full-source negative fixtures)"
