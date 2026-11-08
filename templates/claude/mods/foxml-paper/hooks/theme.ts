// The active palette, rendered from palette.sh; the notebook pane, bands and toasts draw with it.
export const paper = {
  ink: '#{{FG}}',
  dim: '#{{FG_DIM}}',
  note: '#{{COMMENT}}',
  heart: '#{{GARDEN_3}}',
  berry: '#{{GARDEN_4}}',
  ribbon: '#{{WAYBAR_WS_ACTIVE}}',
  added: '#{{CLAUDE_DIFF_ADD_WORD}}',
  removed: '#{{CLAUDE_DIFF_DEL_WORD}}',
} as const
