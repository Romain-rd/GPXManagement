# Architecture technique — Facturation de l'hébergement via Apple IAP

> Étude technique : facturer la **mise en ligne de traces** sur `gpxmanagement.net`
> via l'In-App Purchase Apple (StoreKit 2). Le reste de l'app reste gratuit.
>
> Prérequis assumé : **l'app est distribuée sur le Mac App Store** (StoreKit n'existe
> pas en distribution Developer ID/DMG). Modèle retenu : **abonnement par paliers de
> traces en ligne** + **publication unitaire consommable** comme prix d'appel.

---

## 1. Vue d'ensemble des composants

```mermaid
flowchart TB
    subgraph Mac["App macOS (SwiftUI)"]
        UI["UI export web<br/>+ paywall contextuel"]
        Billing["GPXBilling<br/>(package StoreKit 2)"]
        CK["CloudKit<br/>(appAccountToken)"]
    end

    subgraph Apple["Apple"]
        SK["StoreKit /<br/>App Store"]
        ASN["App Store Server<br/>Notifications V2"]
        Keys["Clés publiques<br/>App Store (JWS)"]
    end

    subgraph Back["Backend gpxmanagement.net"]
        API["API licence/quota<br/>(REST)"]
        Verif["Vérif transactions<br/>JWS + Server API"]
        DB[("Base<br/>comptes / quota /<br/>transactions")]
        Hook["Webhook<br/>notifications Apple"]
    end

    subgraph CDN["Hébergement"]
        Bunny["Bunny CDN<br/>(pull zone)"]
    end

    UI --> Billing
    Billing <-->|"achat / Transaction.updates"| SK
    Billing -->|"appAccountToken"| CK
    Billing -->|"JWS signé + token"| API
    UI -->|"upload trace si quota OK"| API
    API --> Verif
    Verif -.->|"valide signature"| Keys
    Verif -->|"vérif état abo"| SK
    API --> DB
    API -->|"publie fichiers"| Bunny
    SK -->|"renouvellement /<br/>annulation / remboursement"| ASN
    ASN -->|"POST signé"| Hook
    Hook --> DB
```

### Rôles

| Composant | Responsabilité |
|---|---|
| **GPXBilling** (nouveau package) | Charge les produits, déclenche l'achat, écoute `Transaction.updates`, expose l'état d'habilitation à l'UI. Isolé comme `GPXCore`/`GPXStrava` pour un futur portage iOS. |
| **CloudKit** | Stocke l'`appAccountToken` (UUID) pour que l'identité d'achat soit **stable entre les Mac** de Romain (setup multi-machine). |
| **StoreKit / App Store** | Vend les produits, signe chaque transaction en **JWS**, gère le renouvellement des abonnements. |
| **Backend** | Source de vérité du **quota** : vérifie les transactions, mappe abonnement → nombre de traces autorisées, autorise/refuse la mise en ligne, héberge sur Bunny. |
| **App Store Server Notifications V2** | Pousse les événements asynchrones (renouvellement, annulation, remboursement, expiration) vers le backend. Indispensable : l'app peut être fermée au moment du renouvellement. |
| **Bunny CDN** | Stockage/diffusion des exports HTML (déjà en place). |

---

## 2. Produits App Store Connect

```mermaid
flowchart LR
    subgraph Group["Subscription Group : Hébergement"]
        T1["Découverte<br/>auto-renewable<br/>niveau 1 — 3 traces"]
        T2["Aventurier<br/>auto-renewable<br/>niveau 2 — 15 traces"]
        T3["Illimité<br/>auto-renewable<br/>niveau 3 — ∞"]
    end
    Cons["Publication unitaire<br/>consommable<br/>(prix d'appel)"]

    T1 -.->|"upgrade/downgrade<br/>au prorata par Apple"| T2
    T2 -.-> T3
```

- Les 3 paliers vivent dans **un seul subscription group** → Apple gère seul l'upgrade/downgrade proratisé et empêche le cumul.
- Le **consommable** est hors groupe (achat indépendant, re-achetable).
- Apple ne connaît **pas** la sémantique « 3 / 15 / ∞ traces » : c'est le backend qui mappe `productID → quota`.

---

## 3. Flux d'achat (abonnement ou crédit)

```mermaid
sequenceDiagram
    actor U as Utilisateur
    participant App as App (GPXBilling)
    participant SK as StoreKit
    participant API as Backend
    participant DB as Base

    U->>App: clic « Mettre en ligne » (quota atteint)
    App->>App: affiche paywall contextuel
    U->>App: choisit un palier
    App->>App: récupère/crée appAccountToken (CloudKit)
    App->>SK: product.purchase(appAccountToken)
    SK->>U: Face ID / mot de passe
    SK-->>App: VerificationResult<Transaction> (JWS)
    App->>App: vérifie signature locale (StoreKit)
    App->>API: POST /entitlements { jwsTransaction, appAccountToken }
    API->>API: re-vérifie JWS côté serveur
    API->>SK: App Store Server API (état abo, optionnel)
    API->>DB: enregistre transaction + quota
    API-->>App: { quota: 15, expires: ... }
    App->>SK: transaction.finish()
    App-->>U: paywall fermé, mise en ligne débloquée
```

Points clés :
- L'`appAccountToken` (UUID) est **passé à l'achat** → c'est le lien entre la transaction Apple et le compte gpxmanagement.net.
- **Double vérification** : signature validée sur l'app (UX rapide) **et** re-validée côté serveur (sécurité — l'app n'est pas une source de confiance).
- `transaction.finish()` seulement **après** confirmation backend, pour ne pas perdre un achat en cas d'erreur réseau.

---

## 4. Flux de mise en ligne d'une trace (gating quota)

```mermaid
sequenceDiagram
    actor U as Utilisateur
    participant App as App
    participant API as Backend
    participant DB as Base
    participant Bunny as Bunny CDN

    U->>App: « Mettre en ligne » cette trace
    App->>API: POST /publish { appAccountToken, traceId, files }
    API->>DB: lit quota + nb traces déjà en ligne
    alt quota disponible
        API->>Bunny: upload export HTML
        API->>DB: marque trace en ligne (+1)
        API-->>App: 200 { url publique }
        App-->>U: lien copié / ouvert
    else quota atteint
        API-->>App: 402 Payment Required { quota, used }
        App-->>U: paywall (upgrade de palier)
    end
```

- Le **backend est l'arbitre** du quota — jamais l'app (contournable).
- Retirer une trace en ligne décrémente le compteur → un slot se libère (cohérent avec le modèle « stock »).

---

## 5. Événements asynchrones (renouvellement / annulation / remboursement)

```mermaid
sequenceDiagram
    participant SK as App Store
    participant Hook as Webhook backend
    participant DB as Base
    participant App as App (au prochain lancement)

    Note over SK: renouvellement mensuel,<br/>annulation, remboursement,<br/>expiration, changement de palier
    SK->>Hook: POST notification V2 (JWS signé)
    Hook->>Hook: vérifie signature
    Hook->>DB: met à jour état abo + quota

    alt remboursement / expiration
        DB->>DB: quota → 0 (ou palier inférieur)
        Note over DB: traces au-delà du quota :<br/>grâce 30 j puis dépublication
    end

    App->>SK: Transaction.updates (au lancement)
    App->>DB: re-sync état (source de vérité = backend)
```

- **App Store Server Notifications V2** est la seule façon fiable de savoir qu'un abonnement s'est renouvelé/annulé **app fermée**.
- Politique de dépassement à définir : période de grâce avant dépublication des traces excédentaires (recommandé pour ne pas casser des liens partagés brutalement).

---

## 6. Restauration & multi-machine

```mermaid
flowchart LR
    M1["Mac 1"] -->|"écrit appAccountToken"| CK[("CloudKit")]
    M2["Mac 2"] -->|"lit appAccountToken"| CK
    M1 -->|"Transaction.currentEntitlements"| SK["StoreKit"]
    M2 -->|"Transaction.currentEntitlements"| SK
    M1 --> API["Backend<br/>(même compte)"]
    M2 --> API
```

- L'`appAccountToken` synchronisé via **CloudKit** garantit que les deux Mac pointent vers **le même compte** côté backend.
- `Transaction.currentEntitlements` permet de **restaurer** l'abonnement sans nouvel achat (même Apple ID).
- Aucun bouton « Restaurer » obligatoire avec StoreKit 2 : les entitlements sont déjà disponibles, mais en prévoir un pour rassurer.

---

## 7. Machine à états du quota (côté backend)

```mermaid
stateDiagram-v2
    [*] --> Gratuit
    Gratuit --> Actif: achat abo
    Actif --> Actif: renouvellement
    Actif --> Grace: échec paiement
    Grace --> Actif: paiement régularisé
    Grace --> Expire: délai dépassé
    Actif --> Annule: annulation utilisateur
    Annule --> Actif: réactivation
    Annule --> Expire: fin de période payée
    Expire --> Gratuit: quota → 0
    Actif --> Rembourse: remboursement Apple
    Rembourse --> Gratuit: quota → 0

    note right of Expire
        Traces au-delà du
        nouveau quota :
        grâce 30 j puis
        dépublication
    end note
```

---

## 8. Modèle de données backend (minimal)

```mermaid
erDiagram
    ACCOUNT ||--o{ TRANSACTION : possede
    ACCOUNT ||--o{ HOSTED_TRACE : heberge
    ACCOUNT {
        uuid app_account_token PK
        string original_transaction_id
        string tier
        int quota
        datetime expires_at
        string status
    }
    TRANSACTION {
        string transaction_id PK
        string product_id
        string type
        datetime purchased_at
        int credits_added
    }
    HOSTED_TRACE {
        string trace_id PK
        string bunny_path
        string public_url
        datetime published_at
        bool active
    }
```

- `app_account_token` = clé d'identité (généré par l'app, lié à l'Apple ID via la transaction).
- `quota` recalculé à chaque notification Apple (abo) + crédits consommables.
- `HOSTED_TRACE.active` permet la dépublication sans perdre l'historique.

---

## 9. Sécurité — points non négociables

```mermaid
flowchart TB
    A["Transaction reçue"] --> B{"Signature JWS<br/>valide ?"}
    B -->|non| R["Rejet"]
    B -->|oui| C{"bundleId + env<br/>(prod/sandbox)<br/>cohérents ?"}
    C -->|non| R
    C -->|oui| D{"transactionId<br/>déjà consommé ?"}
    D -->|oui| R
    D -->|non| E["Provisionne quota / crédits"]
```

- **Toujours re-vérifier la signature côté serveur** avec les clés publiques App Store — l'app n'est pas une source de confiance.
- **Anti-rejeu** : un `transactionId` ne doit créditer qu'une fois.
- **Vérifier l'environnement** (sandbox vs production) pour éviter qu'un achat de test ne crédite en prod.
- Le `client_secret` Strava et toute clé serveur restent **hors repo** (`Secrets.xcconfig` + secrets backend), conformément à la règle projet.

---

## 10. Décisions ouvertes

1. **Backend** : techno et hébergement (un petit service suffit — vérif JWS + quota + webhook). Aujourd'hui l'export pousse des fichiers statiques sur Bunny sans serveur ; l'IAP **impose** un composant serveur.
2. **Coût réel par trace hébergée** (stockage + bande passante Bunny) → fixe les seuils des paliers.
3. **Politique de dépassement** après expiration/downgrade : durée de grâce, ordre de dépublication.
4. **Crédits consommables** : durée d'hébergement par crédit (permanent = coût non couvert, à borner).
5. **Chemin minimal possible** : démarrer sans backend en vérifiant les entitlements **on-device** (StoreKit 2 valide la signature localement) et en stockant le quota dans CloudKit — plus simple, mais quota contournable et pas de webhook fiable. À réserver à un MVP.
```
