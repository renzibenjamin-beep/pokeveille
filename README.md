# PokéVeille 30 ans

Surveillance automatique des stocks des produits Pokémon **30 ans** (Auchan, boutiques spécialisées, signalements Dealabs).
Une alerte part sur le téléphone (ntfy) dès qu'un produit est disponible **au prix magasin** ou signalé **en magasin**.

Ce dépôt tourne tout seul avec GitHub Actions, toutes les 10 minutes environ (onglet **Actions**).

- Les réglages et les prix de référence sont dans `config.json` et `catalogue.json`. Ils sont mis à jour depuis le PC avec « Publier sur GitHub.bat ».
- Le sujet ntfy est stocké dans un **secret** du dépôt (`NTFY_TOPIC`) et n'apparaît jamais dans les fichiers.
