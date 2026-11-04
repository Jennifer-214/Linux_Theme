if "{{LITTLE_DETAILS}}" == "fox-little-details-on" then
  -- foxml:icon-family-begin
  -- foxml:icon-family-end
  local inherited_icon = Entity.icon
  function Entity:icon()
    -- Metadata takes precedence over a link's filename extension.
    local icon = self._file.link_to and paper_icons.symlink
      or self._file.cha.is_dir and (paper_icons.directories[self._file.name] or paper_icons.directory)
    if not icon then return inherited_icon(self) end
    if self._file.is_hovered then return icon.text .. " " end
    return ui.Line(icon.text .. " "):fg(icon.fg)
  end
end
