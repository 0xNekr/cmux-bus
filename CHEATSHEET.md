# cmux-bus — Cheat Sheet

Bus multi-agents pour cmux. Un log append-only par **workspace cmux**, piloté par
les commandes `agent-*`. Tout agent dans le même workspace tombe sur le même bus.

---

## 🚀 Démarrage rapide

```sh
# Dans chaque pane cmux, un agent s'enregistre une fois :
agent-init claude --lead        # toi = lead (orchestrateur, strict par défaut)
agent-init codex                # un worker
agent-init codex --as codex     # idem mais déclare son provider (pour la policy)

agent-roster                    # qui es-tu, qui est là, qui est lead, policies
agent-inbox                     # tes threads ouverts (à lire AVANT toute tâche)
```

> Scope : par défaut **workspace** (isolé par `CMUX_WORKSPACE_ID`).
> `--scope repo` pour un `.agents/` partagé par dossier. `--bus-dir DIR` pour forcer.

---

## 💬 Communiquer

```sh
agent-send <to> <type> [--ref ID] [--paths "a,b"] [--status S] <body>
#   types : ask | handoff | ack | done | block
agent-send codex handoff --paths "src/**" "Implémente X, réponds done avec le diff"
agent-send all ask "GO / NO-GO sur cette approche ?"     # fan-out (ou: a,b,c)

agent-inbox                     # threads adressés à toi  (--only-stuck, --only-stale)
agent-thread <id>               # historique complet d'un thread  (--json)
agent-done <id> [body]          # clôt un thread
```

| Type | Sens |
|---|---|
| `ask` | ouvre un thread, demande un avis |
| `handoff` | délègue une tâche (le receveur fait `ack` puis `done`) |
| `ack` | accuse réception → `in_progress` |
| `done` | clôt avec le résultat |
| `block` | escalade vers `user` quand bloqué |

---

## 👑 Lead & équipe

```sh
agent-lead                      # affiche le lead + sa policy d'exécution
agent-lead set claude           # désigne le lead (STRICT par défaut)
agent-lead relaxed | strict     # bascule la policy d'exécution
agent-lead clear                # retour peer-to-peer
```

**Lead STRICT (défaut)** : délègue tout, **n'édite/n'exécute rien lui-même**,
sauf instruction explicite de l'utilisateur. `relaxed` = peut exécuter directement.

**Le lead constitue son équipe lui-même :**

```sh
agent-spawn <name> --as <claude|codex|opencode> [--model M] \
            [--task "..." --paths "..."] [--split [--dir D]] [--title T|--no-rename] [--no-say]
agent-spawn fixer --as codex --task "Bisecte le test flaky" --paths "tests/**"
#   → ouvre un ONGLET en arrière-plan dans ton pane (non focalisé, cliquable),
#     enregistre le worker, lance son CLI, renomme l'onglet "<model> - <provider>"
#     (ex: "gpt-5.4 - codex"), et (avec --task) lui sème un premier handoff.
#   → --split pour un pane côte-à-côte au lieu d'un onglet.
#   → opencode : le modèle passe par OPENCODE_CONFIG_CONTENT (le TUI n'a pas de --model).

agent-fleet a=codex b=claude c=opencode:opencode-go/qwen3.7-max
#   → monte toute une escouade d'un coup (1 worker par spec), en onglets

agent-dismiss <name>            # ferme le pane + désenregistre
agent-dismiss --done            # ferme les workers dont le thread est fini
agent-dismiss --all-spawned     # démonte toute l'équipe spawnée
```

> `agent-roster` montre provider/modèle des workers spawnés (colonne **VIA**).

---

## 🔒 Policies

**Qui peut exécuter** (lead) — voir `agent-lead`. STRICT par défaut.

```sh
# Enforcement réel du lead strict via hook Claude Code (opt-in) :
agent-lead-guard install     # deny sous-agents natifs, ask edits/exec, allow délégation+lecture
agent-lead-guard status      # voir s'il est câblé
agent-lead-guard uninstall   # retirer
#   → fail-open : n'agit que si TON pane est le lead strict, sinon invisible.
```


**Qui peut créer qui** (spawn) — appliqué par `agent-spawn`/`agent-fleet` :

```sh
agent-policy show               # mode résolu + règles + sources
agent-policy check claude codex # teste une règle (allow / deny)
agent-policy init --repo        # crée une policy committable pour CE repo
agent-policy init --user        # crée une policy globale (~/.config/cmux-bus/)
agent-policy path [--user|--repo]
```

Résolution (le plus tardif gagne) : **builtin `open` ⟵ user ⟵ repo**.

```jsonc
// .cmux-bus/policy.json  (par repo, committable)   ou  ~/.config/cmux-bus/policy.json
{ "spawn": { "mode": "matrix", "rules": {
    "lead":   ["*"],                  // le lead peut tout spawner
    "claude": ["codex", "opencode"],  // claude peut spawner codex/opencode
    "codex":  []                      // codex ne peut rien spawner
} } }
```

Modes : `open` (défaut, tout permis) · `lead-only` (seul le lead) · `matrix` (règles ci-dessus).
Clé d'un appelant = son **provider** (`.meta`, via `agent-spawn` ou `agent-init --as`),
le rôle `lead`, ou `default`. `*` = n'importe quel provider.

**Providers & modèles par défaut** (utilisés par spawn/fleet) :

```sh
agent-providers list            # claude=opus, codex=gpt-5.4, opencode=anthropic/...
agent-providers init            # personnalise (survit à ./install.sh)
agent-providers get codex default_model
```

---

## 🔁 Orchestration synchrone

```sh
agent-rpc <agent> <body>        # un ask → attend la réponse → l'imprime
agent-wait <id>                 # bloque jusqu'à done/blocked  (--timeout, --status)
agent-synthesize <id...>        # collecte les réponses finales de N threads (fan-in)
agent-playbook run <name> [K=V] # workflow JSON (send/wait/rpc + interpolation)
```

---

## 🚑 Récupération

```sh
agent-cancel <id> [reason]      # abandonne un thread (block vers user)
agent-resume <id> [body]        # relance un thread bloqué/crashé vers son destinataire
```

---

## 🛡️ Sûreté & intégrité

```sh
agent-guard check [--staged] [--all]   # fichiers en conflit avec des paths_claimed ouverts
agent-guard install                    # hook git pre-commit
agent-doctor                           # valide bus + registre (JSONL, ids, refs, stuck)
agent-repair [--dry-run]               # répare un bus.jsonl corrompu (backup horodaté)
```

---

## 👀 Observation & maintenance

```sh
agent-watch [--once] [--me] [--full]   # flux live du bus
agent-roster [--json]                  # qui est là (live/stale), lead, policies, VIA
agent-update                           # met à jour cmux-bus + re-run install.sh
```

---

## 🧭 Recettes courantes

**Délégation simple (lead → worker existant)**
```sh
agent-send codex handoff --paths "api/**" "Ajoute l'endpoint /health, réponds done"
agent-wait <id>                 # ou laisse le signal te réveiller
```

**Lead recrute, délègue, nettoie (le flux complet)**
```sh
agent-spawn dbfix --as codex --task "Corrige la migration cassée, done avec le diff" --paths "db/**"
# ... tu reviews le done ...
agent-dismiss dbfix
```

**Verrouiller la création d'agents sur un repo sensible**
```sh
agent-policy init --repo        # puis édite .cmux-bus/policy.json en mode lead-only
agent-policy check codex claude # vérifie : deny attendu
```

**Question à toute l'équipe puis synthèse**
```sh
ids=$(agent-send all ask "Quelle approche pour le cache ?")
agent-synthesize $ids
```

---

## 📋 Aide-mémoire schéma d'événement

```json
{ "id","ts","from","to","type","ref","status","paths_claimed","cwd","body" }
```
État d'un thread = **dernier** événement de sa chaîne (`ref`). Le bus est append-only.

> Toute commande accepte `--scope repo|workspace` et `--bus-dir DIR`.
> Aide d'une commande : lance-la sans argument (ou avec une mauvaise option).
