imap_spike_deps = [
  dependency('glib-2.0', version: '>= 2.80'),
  dependency('gio-2.0', version: '>= 2.80'),
]

executable(
  'letter-imap-spike',
  files(
    meson.project_source_root() / 'src' / 'engine' / 'imap-client.vala',
    'main.vala',
  ),
  dependencies: imap_spike_deps,
  install: false,
)
