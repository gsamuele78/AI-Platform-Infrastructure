# Keycloak Client for the AI Platform (DEC-001)

| | |
| :-- | :-- |
| **For** | Infra-IAM administrators (Keycloak realm in [Infra-Iam-PKI](https://github.com/gsamuele78/Infra-Iam-PKI)) |
| **Result** | BIOME researchers log in to the web chat with their institutional account; access and admin rights come from Keycloak roles, project sharing from Keycloak groups |
| **Platform side** | `compose.yaml` (Open WebUI `OAUTH_*`), `.env` (`OIDC_*`), policy test in `tests/compose/policy.bats` |
| **Verified against** | Open WebUI v0.11.4 source (`backend/open_webui/config.py`, `utils/oauth.py`) |

## 1. Client

| Setting | Value |
| :-- | :-- |
| Client ID | `lifewatch-ai-platform` (= `OIDC_CLIENT_ID`) |
| Client type | OpenID Connect, **confidential** (client authentication on) |
| Flows | Standard flow only. Direct access grants, implicit flow and service accounts **off** |
| Valid redirect URI | `https://<PUBLIC_HOSTNAME>/oauth/oidc/callback` (exact, no wildcard) |
| Web origins | `https://<PUBLIC_HOSTNAME>` |
| Client secret | into the platform's `.env` as `OIDC_CLIENT_SECRET` (mode 600), never into git or tickets |
| Discovery URL | `https://<keycloak>/realms/<realm>/.well-known/openid-configuration` (= `OIDC_DISCOVERY_URL`) |

## 2. Roles: who may use the platform

Create two **client roles** on `lifewatch-ai-platform`:

| Role | Open WebUI result |
| :-- | :-- |
| `ai-user` | role `user`: chat, own documents, models shared with them |
| `ai-admin` | role `admin`: users, groups, models, knowledge, settings |

Assign them through groups, not to people one by one. For example, the AD group of the BIOME group gets `ai-user`, and the platform team gets `ai-admin`.

**Mapper** (Client → Client scopes → `lifewatch-ai-platform-dedicated` → Add mapper → *User Client Role*):

| Field | Value |
| :-- | :-- |
| Client ID | `lifewatch-ai-platform` |
| Token claim name | `lifewatch_roles` (= `OIDC_ROLES_CLAIM`) |
| Multivalued | on |
| Add to ID token / access token / userinfo | on / on / **on** |

Open WebUI reads roles from the ID token and userinfo, and Keycloak's built-in client-role mapper writes only to the access token (`resource_access.<client>.roles`). That is why a dedicated, flat claim is used.

How Open WebUI v0.11.4 decides (`get_user_role`):

| Token has | Result |
| :-- | :-- |
| `ai-admin` in `lifewatch_roles` | admin |
| `ai-user` in `lifewatch_roles` | user |
| `lifewatch_roles` with neither | **login refused (403)** |
| no `lifewatch_roles` claim at all | account created as `pending`: an admin must approve it |
| very first account on an empty instance | admin (bootstrap, regardless of roles) |

The last row is why RUNBOOK §3 still has the operator log in first, through an SSH tunnel, before the firewall opens.

## 3. Groups: who sees which model or knowledge base

**Mapper** (same dedicated scope → *Group Membership*):

| Field | Value |
| :-- | :-- |
| Token claim name | `groups` (= `OIDC_GROUPS_CLAIM`) |
| Full group path | **off** (names, not `/a/b/c` paths) |
| Add to ID token / userinfo | on / on |

The platform syncs memberships into **existing** Open WebUI groups with the same name (`ENABLE_OAUTH_GROUP_MANAGEMENT=true`), and never creates groups itself (`ENABLE_OAUTH_GROUP_CREATION=false`), so a user in 300 AD groups does not produce 300 Open WebUI groups. An admin creates the groups that matter (for example `biome-pollinators`, `lifewatch-plus`) and uses them to share knowledge bases and models.

## 4. API access (not through Keycloak)

Programs, notebooks and coding agents do **not** log in through Keycloak: LiteLLM's JWT validation requires an Enterprise licence ([ADR-004](../adr/ADR-004-identity-and-rbac-gateway.md)). They use a virtual key issued by the platform team, scoped and rate-limited per client ([ADR-014](../adr/ADR-014-agent-client-contract.md)):

```bash
sudo bash scripts/ops/issue-key.sh --alias <person-or-project> --duration 180d \
  --rpm 60 --tpm 200000 --max-parallel 2 --max-budget 50     # budget in millions of tokens
```

## 5. Checklist for the Infra-IAM ticket

- [ ] Client `lifewatch-ai-platform` created as in §1
- [ ] Client roles `ai-user`, `ai-admin`, mapped through groups
- [ ] Mapper `lifewatch_roles` (ID token + userinfo)
- [ ] Mapper `groups` (no full path)
- [ ] Secret handed over through the agreed secret channel
- [ ] Test login with one `ai-user`, one `ai-admin`, one account with neither (must be refused)
