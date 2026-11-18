fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android check_metadata

```sh
[bundle exec] fastlane android check_metadata
```

Contrôle local de la fiche fr-FR : fichiers présents, non vides, dans les limites de la Play Console

### android internal

```sh
[bundle exec] fastlane android internal
```

Envoie l'AAB release sur la piste de test interne (options : aab, status = completed | draft)

### android metadata

```sh
[bundle exec] fastlane android metadata
```

Envoie la fiche Play fr-FR (titre, descriptions), sans AAB ni images (option : validate_only)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
