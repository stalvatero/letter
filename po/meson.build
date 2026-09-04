i18n.gettext(meson.project_name(), preset: 'glib')

# Compile .mo files into the build locale dir so `meson devenv` can find them.
fs = import('fs')
langs = fs.read('LINGUAS').strip().split('\n')
locale_root = meson.project_build_root() / 'locale'
sh = find_program('sh')
compile_locale = files('compile-locale.sh')

foreach lang : langs
  lang = lang.strip()
  if lang == '' or lang.startswith('#')
    continue
  endif

  custom_target(
    'locale-' + lang,
    input: lang + '.po',
    output: lang + '.mo',
    command: [
      sh,
      compile_locale,
      '@INPUT@',
      '@OUTPUT@',
      locale_root,
      lang,
      meson.project_name(),
    ],
    build_by_default: true,
  )
endforeach
