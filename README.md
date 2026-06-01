# WildDuck Mail Server (IMAP/POP3/SMTP)

Servidor de correo auto-hospedado para que clientes externos (Thunderbird, Outlook, Apple Mail) puedan conectarse vía IMAP/POP3/SMTP a tu dominio, integrado con el webmail existente.

## Arquitectura

```
                     Internet
                        │
            ┌───────────┴────────────┐
            │                        │
   (1) Cloudflare Email Routing   (2) IMAP/POP3/SMTP clients
            │                        │
            ▼                        ▼
   ┌─────────────────┐    ┌──────────────────┐
   │  worker.js      │    │  Oracle Cloud VM │
   │  (Cloudflare)   │    │  1 GB RAM ARM    │
   │                 │    │                  │
   │  Parse MIME →   │    │  ┌────────────┐  │
   │  POST /ingress  │    │  │ WildDuck   │  │
   └─────────────────┘    │  │ :993 :995  │  │
            │             │  │ :587 :8080 │  │
            ▼             │  └─────┬──────┘  │
   ┌─────────────────┐    │        │         │
   │ Next.js (Vercel)│    │        │         │
   │ webmail + REST  │◄───┼────────┘         │
   │ proxy to :8080  │    │                  │
   └─────────────────┘    └────────┬─────────┘
            │                       │
            │   ┌───────────────────┘
            ▼   ▼
       ┌─────────────────┐
       │  MongoDB Atlas  │  (free M0 tier, shared with webmail)
       │  mailservice DB │
       │  + wildduck DB  │
       └─────────────────┘
```

### Flujos

- **Recepción (entrada)**: Cloudflare Email Routing recibe el correo → `worker.js` lo parsea y lo envía al endpoint `/api/emails/ingress` → se guarda en MongoDB y se refleja en WildDuck para que aparezca vía IMAP
- **Envío (salida)**: Cliente externo → SMTP submission (puerto 587) en WildDuck → relay a Mailjet (mismo proveedor que ya usas)
- **Lectura (cliente)**: Cliente externo → IMAPS (puerto 993) en WildDuck → MongoDB

## Componentes instalados en `mail-server/`

| Archivo | Propósito |
|---|---|
| `docker-compose.yml` | Levanta WildDuck y opcionalmente Haraka (relay) |
| `wildduck/wildduck.yml` | Configuración principal de WildDuck |
| `wildduck/.env.example` | Variables de entorno del servidor |
| `wildduck/tls/` | Certificados TLS (Let's Encrypt) y DH params |
| `wildduck/dkim/` | Clave privada DKIM (para firma de salida) |
| `cloudflared/config.yml` | Túnel para exponer REST API vía HTTPS |
| `cloudflared/cloudflared-docker-compose.yml` | Stack separado de Cloudflare Tunnel |
| `docs/DNS.md` | Registros DNS que debes configurar |
| `scripts/setup-oracle.sh` | Instalador automatizado para Oracle Cloud |

## Despliegue paso a paso

### 1. Preparar Oracle Cloud
1. Crea una VM **Always Free** ARM (1 GB RAM) o AMD (1 GB RAM) con Ubuntu 22.04
2. Anota la **IP pública** de la VM
3. **Abre los puertos** 22, 80, 443, 143, 993, 110, 995, 587 en la Security List de la VCN
4. Configura **Reverse DNS** de la IP pública → `mail.tudominio.com`

### 2. Configurar DNS
Sigue [`docs/DNS.md`](docs/DNS.md) para crear:
- Registro A → IP de Oracle
- Registro MX → `mail.tudominio.com`
- SPF, DKIM, DMARC

### 3. Desplegar en la VM

Sube la carpeta `mail-server/` a la VM (por SCP o git clone) y ejecuta:

```bash
cd /opt/mail-server
cp .env.example .env
# Edita .env con tus valores reales
nano .env

# Genera API key (si no la hiciste aún)
echo "WILDDUCK_API_KEY=$(openssl rand -hex 32)" >> .env

# Despliega
sudo bash scripts/setup-oracle.sh
```

### 4. Configurar el webmail (Next.js)

Añade a tu `.env.local`:

```bash
WILDDUCK_API_URL=http://<IP_PUBLICA_ORACLE>:8080
WILDDUCK_API_KEY=<el mismo valor que en Oracle>
IMAP_PUBLIC_HOST=mail.tudominio.com
IMAP_PUBLIC_PORT=993
```

### 5. Probar la conexión

Desde tu máquina local, con un cliente IMAP (Thunderbird) o por línea de comandos:

```bash
# Con openssl (verificar TLS)
openssl s_client -connect mail.tudominio.com:993 -crlf

# Con swaks (verificar SMTP submission + auth)
swaks --to test@gmail.com \
      --from tu@tudominio.com \
      --server mail.tudominio.com:587 \
      --auth-login tu@tudominio.com \
      --auth-password <app-password-generada> \
      --tls --body "Test"
```

## Seguridad

- **App passwords**: nunca expongas la contraseña principal del correo. Cada dispositivo/cliente usa una contraseña de aplicación revocable (16+ caracteres, generada desde la UI de Configuración)
- **Auth deshabilitado en plain**: WildDuck solo acepta AUTH después de STARTTLS, evitando contraseñas en texto claro
- **TLS forzado**: solo TLSv1.2+ con ECDHE+AESGCM
- **CORS restrictivo**: la REST API solo acepta requests desde el dominio del webmail
- **Rate limiting**: 5 intentos de auth por IP cada 5 minutos

## Limitaciones del tier gratuito de Oracle

- **1 GB RAM**: WildDuck + Node.js + TLS caben en ~500-700 MB con los límites del `docker-compose.yml`
- **Sin HA**: si Oracle recicla la VM (por inactividad), pierdes la IP. Usa Cloudflare Tunnel para mitigar
- **Sin dominio IP fija**: cambia tras paros. Cloudflare Tunnel o un script de actualización de DNS lo resuelven
- **Sin block storage**: los certificados Let's Encrypt se regeneran tras reinicios (script `setup-oracle.sh` lo maneja con un volumen Docker)

## Próximos pasos para producción

- [ ] Configurar backup automático de la base de datos WildDuck
- [ ] Configurar monitoring (Prometheus + Grafana vía docker)
- [ ] Activar sieve/filtrado en WildDuck
- [ ] Configurar DMARC reporting (recoger reportes en `dmarc-reports@tudominio.com`)
- [ ] Configurar fail2ban para IMAP
