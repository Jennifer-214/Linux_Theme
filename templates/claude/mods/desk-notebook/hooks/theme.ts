// The active palette, rendered from palette.sh; the notebook pane, bands and toasts draw with it.
export const paper = {
  ink: '#{{FG}}',
  dim: '#{{FG_DIM}}',
  note: '#{{COMMENT}}',
  page: '#{{BG}}',
  heart: '#{{GARDEN_3}}',
  berry: '#{{CLAUDE_ALERT}}',
  ribbon: '#{{WAYBAR_WS_ACTIVE}}',
  added: '#{{GREEN}}',
  removed: '#{{RED}}',
  selection: '#{{SELECTION}}',
  // How the desktop draws (paper, retro or plain): retro keeps to the characters its terminal font has.
  style: '{{DESK_STYLE}}' as 'paper' | 'retro' | 'plain',
} as const
