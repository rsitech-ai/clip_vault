#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_PANEL="$ROOT_DIR/Sources/ClipVault/Views/AIActionPanel.swift"

INLINE_TOOLBAR="$(sed -n '/private var inlineActionToolbar:/,/private var actionButtons:/p' "$AI_PANEL")"
COMPACT_ACTIONS="$(sed -n '/private func compactActionButton/,/private var enhancePromptButton:/p' "$AI_PANEL")"
COMPACT_ENHANCE="$(sed -n '/private var compactEnhancePromptButton:/,/private var header:/p' "$AI_PANEL")"
ASK_STYLE="$(sed -n '/private var styledAskButton:/,/private var askPlaceholder:/p' "$AI_PANEL")"

if [[ "${CLIPVAULT_GLASS_POLICY_FIXTURE:-}" == "inline-native-glass" ]]; then
  ASK_STYLE=$'case .inspector:\n    askButton\n        .clipVaultGlassButtonStyle(prominent: true)\ncase .inline:\n    askButton\n        .clipVaultGlassButtonStyle(prominent: true)'
fi

INSPECTOR_ASK="$(sed -n '/case \.inspector:/,/case \.inline:/p' <<<"$ASK_STYLE" | sed '$d')"
INLINE_ASK="$(sed -n '/case \.inline:/,$p' <<<"$ASK_STYLE")"

if grep -Fq 'ClipVaultGlassContainer' <<<"$INLINE_TOOLBAR"; then
  echo "inline AI actions must not use GlassEffectContainer during persisted-expanded cold launch" >&2
  exit 1
fi

for section in "$COMPACT_ACTIONS" "$COMPACT_ENHANCE"; do
  grep -Fq '.buttonStyle(.plain)' <<<"$section"
  grep -Fq '.clipVaultGlassSurface(' <<<"$section"
  ! grep -Fq '.clipVaultGlassButtonStyle' <<<"$section"
done

grep -Fq '.clipVaultGlassButtonStyle(prominent: true)' <<<"$INSPECTOR_ASK"
! grep -Fq '.buttonStyle(.plain)' <<<"$INSPECTOR_ASK"
! grep -Fq '.clipVaultGlassSurface(' <<<"$INSPECTOR_ASK"

grep -Fq '.buttonStyle(.plain)' <<<"$INLINE_ASK"
grep -Fq '.clipVaultGlassSurface(' <<<"$INLINE_ASK"
! grep -Fq '.clipVaultGlassButtonStyle' <<<"$INLINE_ASK"

echo "AI workspace glass policy passed"
