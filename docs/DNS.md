# Configuración DNS para IMAP/POP3/SMTP

Este documento lista **todos** los registros DNS que necesitas crear para que tu dominio pueda enviar y recibir correo, y para que los clientes externos (Thunderbird, Outlook, Apple Mail) puedan conectarse.

> **Asume**: tu dominio es `broslunas.com` y el subdominio del mail es `mail.broslunas.com`. Sustituye por los tuyos.

---

## 1. Registros de entrega de correo (MX)

Estos registros le dicen al mundo **a dónde entregar** el correo dirigido a tu dominio.

| Tipo | Host | Valor | TTL | Prioridad |
|---|---|---|---|---|
| MX | `@` (o `broslunas.com.`) | `mail.broslunas.com.` | 3600 | 10 |

---

## 2. Registros del servidor de correo (A)

El subdominio `mail.broslunas.com` debe resolver a la IP pública de tu VM en Oracle Cloud.

| Tipo | Host | Valor | TTL |
|---|---|---|---|
| A | `mail.broslunas.com.` | `<IP_PUBLICA_ORACLE>` | 3600 |

> Si la IP de Oracle cambia, actualiza este registro. (Alternativa: Cloudflare Tunnel con un script que mantenga el mapeo actualizado.)

---

## 3. SPF (Sender Policy Framework)

Le dice a los servidores receptores **quién** está autorizado a enviar correo en nombre de tu dominio.

| Tipo | Host | Valor |
|---|---|---|
| TXT | `@` | `v=spf1 mx ip4:<IP_PUBLICA_ORACLE> include:spf.mailjet.com -all` |

- `mx` — permite enviar desde los servidores listados en MX
- `ip4:...` — permite enviar desde la IP de Oracle
- `include:spf.mailjet.com` — necesario porque sigues usando Mailjet para envío desde la web
- `-all` — rechaza todo lo demás (estricto)

---

## 4. DKIM (DomainKeys Identified Mail)

Firma criptográfica que verifica que el correo no fue alterado en tránsito.

### Generar clave privada (en la VM de Oracle)
```bash
mkdir -p /opt/mail-server/wildduck/dkim
openssl genrsa -out /opt/mail-server/wildduck/dkim/dkim_broslunas.pem 2048
openssl rsa -in /opt/mail-server/wildduck/dkim/dkim_broslunas.pem -pubout -outform DER 2>/dev/null \
  | openssl base64 -A
```

### Publicar registro DNS
| Tipo | Host | Valor |
|---|---|---|
| TXT | `dkim._domainkey.broslunas.com.` | `v=DKIM1; k=rsa; p=<BASE64_PUBLICA>` |

> El wildcard `dkim` es el **selector**. WildDuck usará `dkim` por defecto. Si quieres más, crea `selector2`, `selector3`, etc.

### Configurar WildDuck
Edita `wildduck/wildduck.yml` y reemplaza la sección `dkim.keys`:
```yaml
dkim:
  keys:
    - domain: "broslunas.com"
      selector: "dkim"
      privateKey: "/dkim/dkim_broslunas.pem"
```

---

## 5. DMARC (Reporting & Conformance)

Política de cómo los servidores receptores deben tratar el correo que falla SPF o DKIM.

| Tipo | Host | Valor |
|---|---|---|
| TXT | `_dmarc.broslunas.com.` | `v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@broslunas.com; pct=100; adkim=s; aspf=s` |

- `p=quarantine` — los correos que fallen van a spam (usa `p=reject` cuando ya estés seguro)
- `rua=mailto:...` — recibir reportes agregados de servidores que recibieron tu correo
- `adkim=s` y `aspf=s` — modo estricto

---

## 6. PTR / rDNS (Reverse DNS)

**Crítico para la reputación de envío.** La IP de Oracle debe resolver inversamente a `mail.broslunas.com`.

Oracle no lo configura por defecto. Hay que solicitarlo:

1. Ve a la consola de Oracle Cloud → **Compute → Instances → Tu VM**
2. En la página de la instancia, busca la **IP pública**
3. Junto a la IP, haz clic en **"Edit"** y en el campo **"Reverse DNS"** escribe: `mail.broslunas.com.`
4. Guarda y espera 5-30 minutos para propagación

> Sin PTR, **Gmail y Outlook marcarán tu correo como spam** aunque tengas SPF y DKIM correctos.

---

## 7. Puertos abiertos en Oracle (Network Security List)

Los siguientes puertos deben estar **abiertos en la IP pública** de la VM (en la consola de Oracle: **Networking → Virtual Cloud Networks → Tu VCN → Subnet → Security List → Ingress Rules**).

| Puerto | Protocolo | Uso | Restricción sugerida |
|---|---|---|---|
| 22 | TCP | SSH | Tu IP fija |
| 80 | TCP | HTTP (certbot) | Cualquiera |
| 443 | TCP | HTTPS (webmail) | Cualquiera |
| 143 | TCP | IMAP (STARTTLS) | Cualquiera |
| 993 | TCP | IMAPS (TLS) | Cualquiera |
| 110 | TCP | POP3 (STARTTLS) | Cualquiera |
| 995 | TCP | POP3S (TLS) | Cualquiera |
| 587 | TCP | SMTP submission | Cualquiera |
| 25 | TCP | SMTP (opcional) | **Solo si Oracle concede el desbloqueo** |

### Comandos equivalentes con OCI CLI
```bash
# IMAPS
oci network security-list add-ingress-rules \
  --security-list-id $SL_ID \
  --ingress-rules '[
    {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":993,"max":993}}},
    {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":143,"max":143}}},
    {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":995,"max":995}}},
    {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":110,"max":110}}},
    {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":587,"max":587}}}
  ]'
```

---

## 8. Subdominios del Cloudflare Tunnel (opcional)

Si configuras Cloudflare Tunnel, estos son los CNAMEs que debes crear:

| Tipo | Host | Valor |
|---|---|---|
| CNAME | `mail.broslunas.com.` | `<TUNNEL_ID>.cfargotunnel.com.` |
| CNAME | `imap-api.broslunas.com.` | `<TUNNEL_ID>.cfargotunnel.com.` |

> El proxy de Cloudflare (nube naranja) debe estar **desactivado** para registros MX y registros DKIM, pero **activado** para los CNAMEs del tunnel.

---

## 9. Verificación final

Una vez configurado todo, comprueba con estas herramientas online:

- https://mxtoolbox.com/spf.aspx — comprueba SPF
- https://mxtoolbox.com/dkim.aspx — comprueba DKIM
- https://mxtoolbox.com/dmarc.aspx — comprueba DMARC
- https://www.mail-tester.com — envía un correo de prueba y recibe nota 1-10
- https://www.learndmarc.com — valida la cadena completa

**Puntuación objetivo**: 10/10 en mail-tester antes de dar acceso a usuarios reales.

---

## 10. Plantilla unificada (copiar-pegar en Cloudflare DNS)

```
; MX
broslunas.com.        3600  IN  MX   10  mail.broslunas.com.

; A
mail.broslunas.com.   3600  IN  A    <IP_PUBLICA_ORACLE>

; SPF
broslunas.com.        3600  IN  TXT  "v=spf1 mx ip4:<IP> include:spf.mailjet.com -all"

; DKIM
dkim._domainkey.broslunas.com. 3600 IN TXT "v=DKIM1; k=rsa; p=<BASE64>"

; DMARC
_dmarc.broslunas.com. 3600  IN  TXT  "v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@broslunas.com; pct=100; adkim=s; aspf=s"

; Tunnel (opcional)
mail.broslunas.com.       3600  IN  CNAME  <TUNNEL_ID>.cfargotunnel.com.
imap-api.broslunas.com.   3600  IN  CNAME  <TUNNEL_ID>.cfargotunnel.com.
```
