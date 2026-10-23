///Supported event types
enum BetterPlayerEventType {
  initialized,
  play,
  pause,
  seekTo,
  openFullscreen,
  hideFullscreen,
  setVolume,
  progress,
  finished,
  exception,
  controlsVisible,
  controlsHiddenStart,
  controlsHiddenEnd,
  setSpeed,
  changedSubtitles,
  changedTrack,
  changedPlayerVisibility,
  changedResolution,
  pipStart,
  pipStop,
  setupDataSource,
  bufferingStart,
  bufferingUpdate,
  bufferingEnd,
  changedPlaylistItem,

  /// Playing rendition changed, e.g. adaptive streaming moved 720p -> 360p
  /// on a slow network. Parameters: `width`, `height`, `bitrate` (bits/s, 0 if
  /// unknown) and `quality` (label like "720p").
  qualityChanged,
}
