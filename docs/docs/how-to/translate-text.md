---
sidebar_position: 20
title: Translate text
---

Put each language's text in a table, a `.zon` file in your project's resources. Each field
names a key, and its value is the text to show for that key:

```zon
// resources/locales/fr.zon
.{
    .@"menu.play" = "Jouer",
    .@"menu.quit" = "Quitter",
}
```

Quote a key with `.@"..."` when it has dots or spaces in it. Every value must be a string.

## Add the tables and choose a locale

Tell `app.localization` which file holds each locale, then choose one, usually in `init`:

```zig
try app.localization.addTable("en", .init("resources/locales/en.zon"));
try app.localization.addTable("fr", .init("resources/locales/fr.zon"));
try app.localization.setLocale(app.resources(), "fr");
```

`setLocale` reads only the chosen locale's table. If there is no table for a regional locale
such as `fr-CA`, it uses the language's table (`fr`). It fails with `UnknownLocale` when
neither was added, and with `InvalidLocaleTable` when the file isn't keys and strings. If it
fails, the locale already in use stays. Call it again whenever the player picks another
language.

## Look up text

```zig
// Borrowed until the locale changes; fall back to your own text if the key is missing.
const play = app.localization.lookup("menu.play") orelse "Play";

// Or a copy you own, with an error for a missing key.
const quit = try app.localization.text(gpa, "menu.quit");
defer gpa.free(quit);
```

`lookup` returns null for a key the table doesn't have. `text` returns `MissingTranslation`
in that case, and `NoLocale` before any locale has been chosen. Neither one returns the key
itself as the text, so you can tell when a translation is missing.
`app.localization.currentLocale()` gives the locale in use, as its table was added.
