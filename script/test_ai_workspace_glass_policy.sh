#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_PANEL="$ROOT_DIR/Sources/ClipVault/Views/AIActionPanel.swift"

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

check_glass_policy() {
  local source="$1"
  local inline_toolbar compact_actions compact_enhance ask_button ask_style inspector_ask inline_ask

  inline_toolbar="$(sed -n '/private var inlineActionToolbar:/,/private var actionButtons:/p' <<<"$source")"
  compact_actions="$(sed -n '/private func compactActionButton/,/private var enhancePromptButton:/p' <<<"$source")"
  compact_enhance="$(sed -n '/private var compactEnhancePromptButton:/,/private var header:/p' <<<"$source")"
  ask_button="$(sed -n '/private var askButton:/,/private var styledAskButton:/p' <<<"$source")"
  ask_style="$(sed -n '/private var styledAskButton:/,/private var askPlaceholder:/p' <<<"$source")"
  inspector_ask="$(sed -n '/case \.inspector:/,/case \.inline:/p' <<<"$ask_style" | sed '$d')"
  inline_ask="$(sed -n '/case \.inline:/,$p' <<<"$ask_style")"

  require_absent \
    "$inline_toolbar" \
    'ClipVaultGlassContainer' \
    'inline AI actions must not use GlassEffectContainer during persisted-expanded cold launch' || return 1

  local section
  for section in "$compact_actions" "$compact_enhance"; do
    require_contains "$section" '.buttonStyle(.plain)' 'compact inline actions must use plain button style' || return 1
    require_contains "$section" '.clipVaultGlassSurface(' 'compact inline actions must use the stable material surface' || return 1
    require_absent "$section" '.clipVaultGlassButtonStyle' 'compact inline actions must not use native glass button style' || return 1
    require_absent "$section" '.glassEffect(' 'compact inline actions must not use native glass effects' || return 1
  done

  require_absent "$ask_button" '.clipVaultGlassButtonStyle' 'shared Ask helper must remain placement-neutral and native-glass-free' || return 1
  require_absent "$ask_button" '.glassEffect(' 'shared Ask helper must remain placement-neutral and native-glass-free' || return 1

  require_contains "$inspector_ask" '.clipVaultGlassButtonStyle(prominent: true)' 'inspector Ask must retain prominent native glass' || return 1
  require_absent "$inspector_ask" '.buttonStyle(.plain)' 'inspector Ask must not use the inline plain style' || return 1
  require_absent "$inspector_ask" '.clipVaultGlassSurface(' 'inspector Ask must not use the inline material surface' || return 1

  require_contains "$inline_ask" '.buttonStyle(.plain)' 'inline Ask must use plain button style' || return 1
  require_contains "$inline_ask" '.clipVaultGlassSurface(' 'inline Ask must use the stable material surface' || return 1
  require_absent "$inline_ask" '.clipVaultGlassButtonStyle' 'inline Ask must not use native glass button style' || return 1
  require_absent "$inline_ask" '.glassEffect(' 'inline Ask must not use native glass effects' || return 1
}

mutate_shared_ask_with_native_glass() {
  local source="$1"
  awk '
    /private var askButton:/ { in_ask = 1 }
    in_ask && /\.fixedSize\(horizontal:/ && !injected {
      print
      print "        .clipVaultGlassButtonStyle()"
      injected = 1
      next
    }
    { print }
    /private var styledAskButton:/ { in_ask = 0 }
    END { if (!injected) exit 2 }
  ' <<<"$source"
}

mutate_inline_ask_with_native_glass() {
  local source="$1"
  awk '
    /private var styledAskButton:/ { in_style = 1 }
    in_style && /case \.inline:/ { in_inline = 1 }
    in_inline && /\.buttonStyle\(\.plain\)/ && !injected {
      print
      print "                .clipVaultGlassButtonStyle()"
      injected = 1
      next
    }
    { print }
    /private var askPlaceholder:/ { in_style = 0; in_inline = 0 }
    END { if (!injected) exit 2 }
  ' <<<"$source"
}

SOURCE="$(<"$AI_PANEL")"
SHARED_NATIVE_GLASS_FIXTURE="$(mutate_shared_ask_with_native_glass "$SOURCE")"
INLINE_NATIVE_GLASS_FIXTURE="$(mutate_inline_ask_with_native_glass "$SOURCE")"

if check_glass_policy "$SHARED_NATIVE_GLASS_FIXTURE" >/dev/null 2>&1; then
  fail 'glass policy false-pass: full-source shared Ask native-glass mutation was accepted'
  exit 1
fi

if check_glass_policy "$INLINE_NATIVE_GLASS_FIXTURE" >/dev/null 2>&1; then
  fail 'glass policy false-pass: full-source inline Ask native-glass mutation was accepted'
  exit 1
fi

check_glass_policy "$SOURCE"
echo "AI workspace glass policy passed (production + full-source negative fixtures)"
