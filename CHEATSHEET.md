# cmux-bus — Cheat Sheet

## Independent agents in one workspace

Run this from any pane **before launching independent AI sessions**:

```sh
agent-bus disable       # all panes in this cmux workspace
agent-bus status        # enabled / disabled
agent-bus enable        # explicitly allow coordination again
```

Disabling persists across commands and new panes in the same workspace. It
blocks registration, messaging, spawning, recovery and bus reads (exit code 4),
including attempts through repo scope or an explicit bus directory. Other
workspaces, including those on the same repository, remain enabled. The command
always targets the caller's workspace, ignoring bus environment overrides.
`agent-bus status --quiet` exits 0 when enabled and 1 when disabled.

Panes, agent processes, worktrees and bus history are retained. The canonical
workspace watchdog and notifier are stopped; running bus loops check the switch
on their next iteration. An operation already in flight or text already injected
cannot be recalled. Existing AI conversations may remember their old role: tell
them to continue independently. Bus/lead rules do not apply while disabled;
never re-enable or bypass the switch without an explicit user request.

After `enable`, run `agent-init <name>` in participating panes to resume. Existing
threads are retained, and an independent `agent-notify disable` preference is
preserved. Enabling alone does not launch workers or restart services.


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
agent-spawn --as codex --worktree --task "Implémenter l’API" api
agent-fleet --worktree --base HEAD api=codex ui=claude
agent-worktree list                   # inclut les worktrees conservés
agent-worktree diff api               # contribution depuis le commit de départ
agent-dismiss api                    # conserve branche et fichiers
agent-worktree integrate api --check './tests/run.sh'
agent-worktree remove api             # propre, intégré ; branche conservée
```

Relancer le même nom avec `--worktree` reprend son répertoire, puis utiliser
`agent-resume --force <id>` pour relancer le handoff. La fusion se fait dans un
worktree d’intégration dédié ; en cas d’échec, y résoudre ou annuler la fusion.

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
agent-recover <id> [--max-retries N] [--dry-run]
#   → cascade auto après un timeout : retry (même worker) → reassign (autre peer)
#     → escalate (block vers user). Plafonné, ne boucle jamais.
```

---

## ⏱️ Anti-blocage (watchdog & lease)

```sh
agent-send X handoff --ttl 300 --ack-by 45 "..."  # un handoff = un bail (défauts 300/45s)
agent-watchdog scan                  # une passe : time-out les threads morts/expirés, réveille le lead
agent-watchdog daemon --interval 30  # boucle ; émet un event `timeout` (status blocked) au délégateur
agent-wait <id>                      # borné ; sort en code 3 si le thread a timeout
```
> Principe : le lead attend le **bus**, jamais le worker. Le réveil vient d'un
> timer indépendant (le watchdog), donc un worker mort ne bloque jamais le lead.
> Le `timeout` clôt le thread → libère ses `paths_claimed` et débloque `agent-wait`.

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
{ "id","ts","from","to","type","ref","status","paths_claimed","cwd","body",
  "created_at","ttl","ack_by" }   // 3 derniers = bail (handoffs)
```
`type` : `ask | handoff | ack | done | block | timeout | reassigned`.
État d'un thread = **dernier** événement de sa chaîne (`ref`). Le bus est append-only.

> Toute commande accepte `--scope repo|workspace` et `--bus-dir DIR`.
> Aide d'une commande : lance-la sans argument (ou avec une mauvaise option).
