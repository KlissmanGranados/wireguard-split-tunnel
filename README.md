# Split tunnel WireGuard para KDE Plasma

Este directorio contiene dos scripts para montar un **túnel dividido** con
WireGuard y NetworkManager (el backend que usa KDE Plasma):

| Archivo | Para qué sirve |
|---|---|
| `scripts/update-split-tunnel.sh` | Lee un `.conf` de WireGuard y `domains.txt`, resuelve las IPs actuales y genera `split-tunnel.conf` con un `AllowedIPs` limitado a esos destinos. **No modifica el `.conf` original.** |
| `scripts/apply-split-tunnel-kde.sh` | Importa/actualiza `split-tunnel.conf` en NetworkManager y lo activa. La conexión aparece en el applet de red de Plasma. |
| `domains.txt` | Lista editable de dominios, comodines, IPs y CIDRs que deben ir por la VPN. |
| `generated/split-tunnel.conf` | Configuración generada. Contiene la clave privada; permisos `600`. |

La idea es la misma que la del README de referencia: en WireGuard,
`AllowedIPs` decide qué tráfico entra al túnel. En vez de poner
`0.0.0.0/0`, se ponen únicamente las IPs de los dominios elegidos.

## Menú interactivo (`vpn-cli.sh`)

```bash
./vpn-cli.sh            # menú
./vpn-cli.sh use wg-US-FREE-10.conf && ./vpn-cli.sh apply
./vpn-cli.sh up | down | status
```

Permite elegir el `.conf` de origen, el nombre de la conexión, la interfaz, el
resolver DNS, el descubrimiento de subdominios y el autoconnect, y ejecuta
generar + aplicar en un paso. Las preferencias se guardan en `settings.env`.

### Dónde viven los archivos privados

Los `.conf` (con claves privadas) están dentro del repo pero **ignorados por
git** (`confs/`, `generated/`, `settings.env` y `*.conf` en `.gitignore`), con
permisos `700`/`600`. Se puede mover todo a otra carpeta con `WG_SPLIT_HOME`.

```
vpn/
├── vpn-cli.sh      # menú
├── scripts/        # generar y aplicar
├── domains.txt     # destinos
├── confs/          # .conf de origen: el CLI los lista para elegir (gitignored)
├── generated/      # split-tunnel.conf generado (gitignored)
└── settings.env    # preferencias del CLI (gitignored)
```

Para añadir uno: opción `i` del menú o `./vpn-cli.sh import RUTA.conf`.

## Requisitos

- KDE Plasma con NetworkManager (`nmcli`).
- `dig` (paquete `dnsutils`) para resolver las IPs. Si no está, se usa
  `getent` como alternativa más lenta.
- Opcional: `curl` y `jq` para descubrir subdominios con Certificate
  Transparency (Cert Spotter / crt.sh). Sin ellos, los comodines solo prueban
  una lista de subdominios habituales.
- No hace falta instalar `wg-quick`: la conexión se gestiona con
  NetworkManager, que es lo que usa KDE.

## Uso rápido

```bash
cd ~/programs/vpn

# 1. Edita la lista de dominios
nano domains.txt

# 2. Genera la configuración con las IPs actuales
./scripts/update-split-tunnel.sh

# 3. Aplícala en KDE/NetworkManager
./scripts/apply-split-tunnel-kde.sh
```

Al terminar, la conexión `wg-split` aparece en el applet de red de Plasma y
queda activa. Para ver su estado:

```bash
./scripts/apply-split-tunnel-kde.sh --status
```

Para eliminarla:

```bash
./scripts/apply-split-tunnel-kde.sh --delete
```

Para que se conecte sola al iniciar sesión:

```bash
./scripts/apply-split-tunnel-kde.sh --autoconnect
```

## `domains.txt`

Un destino por línea. Se admiten comentarios con `#`:

```text
# Anthropic / Claude
160.79.104.0/23
claude.ai
*.anthropic.com*

# OpenAI / ChatGPT
chatgpt.com
*.chatgpt.com*
api.openai.com
*.oaistatic.com*
```

Formatos admitidos:

- Dominio exacto: `api.example.com`
- Comodín: `*.example.com` o `*.example.com*`
- CIDR: `160.79.104.0/23`
- IP suelta: `1.2.3.4`
- URL: `https://example.com/ruta` (se usa solo el host)

### Cómo se expanden los comodines

DNS no permite enumerar todos los subdominios de un dominio. Para que
`*.chatgpt.com*` sea útil, el script combina:

1. El dominio base (si el patrón empieza por `*`).
2. Una lista de subdominios habituales (`www`, `api`, `auth`, `cdn`, `ws`,
   `ab`, etc.).
3. Si `curl` y `jq` están disponibles, nombres reales vistos en servicios de
   descubrimiento pasivo (Cert Spotter, HackerTarget, subdomain.center y
   crt.sh, en ese orden).

Los nombres descubiertos se guardan en `.cache/discovery/` durante 24 horas
para no consultar los servicios en cada ejecución. Las IPs se resuelven de
nuevo siempre. Para forzar el descubrimiento:

```bash
./scripts/update-split-tunnel.sh --refresh-discovery
```

Es un enfoque **best-effort**. Si un host crítico no aparece, añádelo de forma
explícita en `domains.txt`. Por ejemplo:

```text
ab.chatgpt.com
cdn.oaistatic.com
```

Si no quieres consultar servicios externos:

```bash
./scripts/update-split-tunnel.sh --no-discover
```

## Actualizar cuando cambien las IPs

Las IPs de Cloudflare/CDN cambian con frecuencia. Vuelve a ejecutar:

```bash
./scripts/update-split-tunnel.sh
./scripts/apply-split-tunnel-kde.sh
```

`update-split-tunnel.sh` escribe primero un archivo temporal y luego lo mueve
de forma atómica, así que `split-tunnel.conf` no queda a medias. El `.conf`
original (`wg-US-FREE-10.conf` en este caso) no se toca.

Opciones útiles del generador:

```bash
./scripts/update-split-tunnel.sh --help
./scripts/update-split-tunnel.sh --no-discover
./scripts/update-split-tunnel.sh -c otro.conf -d otra-lista.txt -o otra-salida.conf
./scripts/update-split-tunnel.sh --dry-run   # muestra el resultado sin escribir
./scripts/update-split-tunnel.sh --verbose   # muestra las IPs una a una
```

## Cómo funciona en KDE

`apply-split-tunnel-kde.sh` usa `nmcli` para:

1. Importar el `.conf` como conexión WireGuard de NetworkManager.
2. Quitar el `DNS` de la VPN (si existiera). En split tunnel, el DNS de la VPN
   no es alcanzable y rompería la resolución.
3. Marcar `ipv4.never-default` / `ipv6.never-default` para que la conexión no
   se convierta en ruta por defecto.
4. Activar `wireguard.peer-routes` para que NetworkManager instale las rutas
   de los `AllowedIPs`.
5. Renombrar la conexión a `wg-split` (o al nombre que indiques) y activarla.

La conexión se puede activar/desactivar también desde el applet de red de
Plasma, como cualquier otra conexión.

## Verificar que el split tunnel funciona

Con la conexión activa:

```bash
# Debe salir por la interfaz WireGuard (por ejemplo, wg-split)
ip route get 160.79.104.10

# Debe salir por tu interfaz normal (wifi/ethernet)
ip route get 1.1.1.1

# Ver la conexión y sus direcciones
./scripts/apply-split-tunnel-kde.sh --status
```

También puedes comparar:

```bash
curl -4 https://chatgpt.com
curl -4 https://example.com
```

El primero debería usar la VPN; el segundo, la conexión normal.

## Notas y limitaciones

- **No se configura DNS de la VPN.** Es intencional. Si añades un `DNS = ...`
  al `.conf`, el split tunnel puede dejar de resolver nombres. El script de
  aplicación elimina esa línea al importar.
- **CDNs compartidas.** Muchos dominios de ChatGPT/OpenAI resuelven a IPs de
  Cloudflare compartidas con otros sitios. Al enrutar esas IPs por la VPN,
  también irá por la VPN cualquier otro sitio que use exactamente esa IP.
  Es una limitación del split tunnel basado en IPs, no de los scripts.
- **IPv6.** Se conservan las direcciones IPv6 del `.conf` y se añaden las IPs
  IPv6 resueltas. Si tu red no tiene IPv6, el tráfico IPv6 simplemente no
  funcionará; el IPv4 seguirá funcionando.
- **Túnel completo.** `apply-split-tunnel-kde.sh` rechaza configuraciones con
  `0.0.0.0/0` o `::/0` para evitar accidentes. Si de verdad quieres aplicarlas,
  usa `--allow-full-tunnel`.
- **Clave privada.** `split-tunnel.conf` contiene la clave privada de
  WireGuard. Se crea con permisos `600`. No lo subas a un repositorio ni lo
  compartas. Si usas git, añade `*.conf` a `.gitignore`. El `.conf` original
  también contiene la clave; si sus permisos son demasiado abiertos, puedes
  ajustarlos con `chmod 600 wg-US-FREE-10.conf`.

## Solución de problemas

| Problema | Qué revisar |
|---|---|
| Pocos destinos / faltan IPs de Claude u OpenAI | El DNS de tu red puede devolver IPs de la LAN (se descartan por privadas). El script usa `1.1.1.1` por defecto; cámbialo con `--resolver IP` o usa `--resolver system`. |
| `No se resolvió ninguna IP` | Comprueba la conexión DNS, que `dig` funcione y que `domains.txt` no esté vacío. Prueba `./scripts/update-split-tunnel.sh --no-discover`. |
| `NetworkManager no está en ejecución` | `systemctl status NetworkManager`; en KDE el applet de red debe funcionar. |
| `No se pudo activar` | El endpoint puede estar bloqueado o las credenciales pueden haber caducado. Prueba el `.conf` original con otro cliente WireGuard o cambia de servidor. |
| ChatGPT no carga | Vuelve a ejecutar el generador; las IPs/CDN pueden haber cambiado. Añade hosts explícitos a `domains.txt`. |
| Todo el tráfico va por la VPN | Revisa que `AllowedIPs` en `split-tunnel.conf` no contenga `0.0.0.0/0`. Revisa también que no haya otra conexión WireGuard con ruta por defecto. |
| No resuelve nombres | Asegúrate de que la conexión no tenga DNS de la VPN. El script de aplicación lo elimina; si importaste el `.conf` a mano, quita `DNS = ...`. |
| La conexión no aparece en Plasma | Es una conexión de NetworkManager; comprueba `nmcli connection show` y reinicia el applet o Plasma si hace falta. |
