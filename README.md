# GPXManagement

**Votre bibliothèque de traces GPS, native sur macOS.**

GPXManagement rassemble toutes vos sorties sportives et de plein air — vélo, moto, marche, randonnée, ski — dans une seule application Mac. Vos fichiers GPX/FIT sont centralisés, classés automatiquement, visualisés sur des cartes IGN topographiques et analysés dans le temps. Tout est synchronisé via votre iCloud personnel : rien ne transite par un serveur tiers.

> Application macOS native (SwiftUI), pour un usage personnel. Distribution hors Mac App Store.

---

## Ce que fait l'application

### 📥 Importer vos activités
- **Glisser-déposer** ou import de fichiers `.gpx` / `.fit` / `.tcx`.
- **Strava** : connectez votre compte et synchronisez vos activités GPS automatiquement (OAuth sécurisé, jeton stocké dans le Trousseau).
- **Apple Santé / Exercice** : import depuis l'export `export.xml` de l'app Santé.
- **HealthFit** et autres services : surveillez un dossier iCloud, les nouveaux fichiers déposés vous sont proposés à l'import.
- **Détection automatique des doublons** (par identifiant Strava, ou par date + distance) : pas de sortie en double dans votre bibliothèque.

### 🗂️ Classer et stocker
- Tous vos fichiers sont rangés dans le **dossier iCloud de l'application**, visible dans le Finder.
- **Organisation automatique** selon un modèle configurable (par année, mois, type d'activité, titre…), à la manière de Lightroom.
- Bouton **« Réorganiser maintenant »** pour réappliquer le modèle à toute la bibliothèque.
- **Nommage intelligent** des sorties d'après le parcours (lieu de départ, point notable, arrivée).
- Changement du **type d'activité** à tout moment (menu contextuel par clic droit, sélection multiple possible).

### 🗺️ Visualiser
Trois modes, choisis depuis la barre d'outils :
- **Activités** — le détail d'une sortie sur un seul écran : carte, profil altimétrique et statistiques mises en forme.
- **Vue d'ensemble** — toutes vos traces (ou une sélection) sur une même carte, avec couleurs distinctes.
- **Statistiques** — vos indicateurs agrégés et comparaisons dans le temps.

Fonds de carte commutables, dont les **cartes IGN** (Géoplateforme) :
- IGN Scan 25 (topographique 1:25 000)
- IGN Plan v2
- Cartes des pentes (utile pour le ski / la rando à ski)
- Photographies aériennes
- Plan et satellite MapKit (hors France)

### 📊 Analyser
- Profil altimétrique (altitude et pente le long du parcours).
- Statistiques par période et par type d'activité : distance, dénivelé, durée, nombre de sorties.

### 📤 Exporter et partager
- **PNG** de la carte (vue actuelle ou parcours complet, haute définition) avec indicateur de progression.
- **PDF** : rapport A4 d'une sortie (carte + profil + stats + notes), imprimable.
- **GPX** : ré-export d'une activité.

### 🪟 Confort macOS
- Multi-fenêtres (« Nouvelle fenêtre »).
- Menus dans la barre de menus macOS et raccourcis clavier.
- Sélection multiple native dans la liste.

---

## Prérequis

- **macOS 15 (Sequoia)** ou plus récent.
- Un **compte iCloud** actif (pour la synchronisation et le stockage des fichiers).
- Pour la synchronisation Strava : un **compte Strava**.

---

## Installation

1. Récupérez `GPXManagement.app`.
2. Glissez-la dans votre dossier **Applications**.
3. Au premier lancement, faites un **clic droit → Ouvrir** (application distribuée hors Mac App Store).
4. Autorisez l'accès à iCloud lorsque macOS le demande.

> La distribution signée et notarisée (DMG) est prévue ; en attendant, le premier lancement peut nécessiter une autorisation manuelle dans Réglages Système → Confidentialité et sécurité.

---

## Connexion à Strava

1. Ouvrez **Réglages → Strava**.
2. Cliquez sur **« Connect with Strava »** : l'autorisation se fait dans votre navigateur.
3. Une fois connecté, utilisez **« Synchroniser maintenant »** pour importer vos activités.

La synchronisation reprend automatiquement là où elle s'est arrêtée et déduplique les sorties déjà présentes.

### Importer depuis un export Strava (sans connexion)

Si vous préférez ne pas connecter votre compte, vous pouvez importer l'archive complète de vos activités :

1. Sur **strava.com**, allez dans **Réglages → Mon compte → Télécharger ou supprimer votre compte**.
2. Sous *Télécharger une demande*, cliquez sur **Demander votre archive**. Strava vous enverra un e-mail avec un fichier ZIP (cela peut prendre quelques heures).
3. Téléchargez et décompressez le ZIP : le dossier **`activities`** contient toutes vos traces (GPX/FIT/TCX).
4. Dans GPXManagement, lancez l'import de ce dossier — les activités sont ajoutées avec déduplication automatique (aucun doublon si vous avez déjà synchronisé via Strava).

---

## Confidentialité

- Vos traces et métadonnées restent sur **votre Mac et votre iCloud personnel**.
- Aucune donnée n'est envoyée à un tiers, hormis les échanges avec **Strava** (si vous l'avez connecté) et le chargement des **tuiles de carte IGN**.
- Les jetons d'accès Strava sont stockés de façon chiffrée dans le **Trousseau macOS**.

---

## Feuille de route

- Édition de traces (découper, fusionner, nettoyer les points aberrants, lisser).
- Distribution signée Developer ID + notarisation Apple (DMG).

---

## Crédits

- Cartes : **Géoplateforme / IGN**.
- Données d'activités : **Strava** — *Powered by Strava*. Strava et le logo Strava sont des marques de Strava, Inc.
- Développé avec SwiftUI, MapKit, Core Data + CloudKit et Swift Charts.
