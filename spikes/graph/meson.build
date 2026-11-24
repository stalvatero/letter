graph_spike_deps = [
  dependency('glib-2.0', version: '>= 2.80'),
  dependency('gio-2.0', version: '>= 2.80'),
  dependency('libsoup-3.0', version: '>= 3.0'),
  dependency('json-glib-1.0', version: '>= 1.6'),
]

executable(
  'letter-graph-spike',
  files(
    'pkce.vala',
    'oauth-pkce.vala',
    'graph-client.vala',
    'main.vala',
  ),
  dependencies: graph_spike_deps,
  install: false,
)
