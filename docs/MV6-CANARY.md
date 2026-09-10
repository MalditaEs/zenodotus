# MV-6 — Despliegue canario hacia el orquestador

Cómo pasa producción de Hypatia al orquestador Mitropoulos (y por tanto a Antena) por partes,
y cómo decidimos que ha funcionado. Se apoya en `STAGING.md`, que cubre el bucle aislado de
staging; este documento va de producción.

Antena ya está validada de por sí, y YouTube funciona de punta a punta a través del
orquestador. Así que este canario **no** prueba si Antena sabe scrapear. Prueba la
**integración**: el mapeo del orquestador a las formas que espera Zenodotus, que los medios
lleguen al bucket, y que el bucle del callback se cierre con tráfico real. Esa distinción es
la que determina qué medimos y por qué no tapamos los fallos.

## Decisiones

**D1 — Enrutar por scrape, y persistir la decisión.**
Una columna nueva, `scrapes.backend`, registra a qué sistema se envió cada scrape, escrita una
vez y reutilizada. Dependen de ella tres cosas: los reintentos de Sidekiq no pueden volver a
tirar el dado (un scrape que fue al orquestador en el intento 1 no puede acabar en Hypatia en
el 2, o los números no significan nada); el callback necesita saber qué sistema le está
contestando; y todo el sentido de un canario es poder hacer un `GROUP BY` después.

**D2 — Flipper para el dial, no una variable de entorno.**
Flipper ya es una dependencia (`flipper`, `flipper-active_record`, con sus tablas en el
esquema) y ya se usa (`Flipper.enabled?(:adhoc, current_user)`). Usamos
`percentage_of_actors`, nunca `percentage_of_time`: hashea el `flipper_id` del actor
(`"Scrape;<uuid>"`), así que el mismo scrape recibe siempre la misma respuesta, y subir el
porcentaje sólo *añade* scrapes. La ventaja decisiva sobre una variable de entorno es el
interruptor de emergencia: `Flipper.disable` surte efecto de inmediato, sin desplegar y sin
reiniciar.

**D3 — Un dial por plataforma.**
`orchestrator_canary_twitter`, `orchestrator_canary_instagram`, y así. A ~100 scrapes al día,
un 10% uniforme repartido entre cinco plataformas da ~2 scrapes por plataforma y día, que no
responde a nada en ningún plazo útil. Concentrar el mismo radio de explosión en una plataforma
cada vez da ~20/día para esa plataforma. Ver "Por qué no un 10% uniforme" más abajo.

**D4 — Dos niveles de interruptor, fallando hacia Hypatia.**
`USE_ORCHESTRATOR` sigue siendo la llave maestra (variable de entorno, requiere despliegue,
apaga todo); Flipper es el dial fino. Cualquier excepción al consultar Flipper se reporta y se
enruta a Hypatia. Un problema en el sistema de feature flags no puede tumbar el scraping ni
mandar tráfico a donde no toca.

**D5 — Sin fallback automático a Hypatia.**
Reenviar a Hypatia un scrape que ha fallado en el orquestador escondería justo la señal que
estamos recogiendo: cada fallo reparado en silencio, un panel marcando 100%, y ni idea de que
la integración está rota. Como Antena ya está probada, los fallos que esperamos son fallos
*sistemáticos* de integración (un campo que el mapeo pierde, un vídeo que nunca llega al
bucket), que son precisamente los que un fallback vuelve invisibles.

La red de seguridad es **manual**: una acción de admin que reencola el scrape explícitamente en
Hypatia y deja constancia. Cuántos rescates has tenido que hacer *es* la tasa de fallo, medida
con honestidad.

**D6 — Un temporizador de callback por scrape, no un barrido periódico.**
Hoy, un scrape cuyo callback no llega nunca se queda en `fulfilled: false, error: nil`
**para siempre**: ni cumplido ni errado, ausente de toda métrica de error, invisible salvo
como un número en el panel de admin que parece simplemente lento. La única recuperación es el
botón de "resubmit all unfulfilled". Este es, con diferencia, el modo de fallo más probable de
la vía del orquestador — es el único con un salto asíncrono de vuelta por la red — y hay que
cerrarlo antes de empezar el canario, o los fallos no serán ni visibles ni recuperables.

El proyecto no tiene scheduler (ni `sidekiq-cron`, ni `whenever`, ni `clockwork`), así que en
vez de introducir uno armamos un `ScrapeTimeoutJob` retardado en cada despacho:
`ScrapeTimeoutJob.set(wait: 30.minutes).perform_later(scrape)`. Sin dependencia nueva, sin
sondeo, y el trabajo salta exactamente cuando hace falta. 30 minutos = el techo de sondeo de
20 minutos del propio orquestador (`poll_max_minutes`) más holgura.

*Sesgo conocido, escrito para que nadie lea mal el informe:* el temporizador se arma sólo para
los scrapes del orquestador, así que al orquestador se le marcan errores que el histórico de
Hypatia nunca tuvo. Eso inclina la comparación **en contra** del orquestador, que es la
dirección correcta en la que equivocarse en una decisión de seguridad. La tasa de atascados de
la propia Hypatia se puede recuperar del histórico (`fulfilled: false, error: nil` con backend
nulo) si queremos el número comparable.

**D7 — La autenticación del callback pasa a ser por scrape.**
La comprobación del bearer que entró con el trabajo del orquestador es todo-o-nada por
despliegue, lo cual es incompatible con un canario: durante el despliegue la mayoría de los
callbacks vienen de Hypatia sin bearer y algunos del orquestador con él. Poner
`ZENODOTUS_CALLBACK_TOKEN` hoy daría 401 a la mayor parte de producción; dejarlo sin poner
renuncia a la protección durante todo el despliegue.

Así que el requisito se traslada al scrape: un callback para un scrape enrutado al orquestador
tiene que traer un bearer válido; el de un scrape de Hypatia mantiene la vía abierta de
siempre. El tráfico queda protegido desde el primer día del canario, y cuando el despliegue
llegue al 100% el endpoint queda cerrado sin ningún cambio más.

*Contrapartida:* el 401 ya no puede lanzarse antes de parsear el cuerpo, así que un llamante no
autenticado vuelve a poder distinguir un id de scrape real de uno inventado. Los ids de scrape
son UUIDv4 y no se pueden enumerar, así que ese oráculo es débil y el intercambio compensa.
`ZENODOTUS_CALLBACK_REQUIRED=true` fuerza el bearer para *todos* los callbacks
independientemente del backend: el interruptor de la fase 4, cuando Hypatia ya no esté.

**D8 — Medir desenlaces y latencia ahora; comparar contenido a mano.**
`ArchiveItem` es un delegated type, así que la completitud campo a campo (captura, vídeo,
autor, texto) vive en una tabla distinta por plataforma y automatizarla es un proyecto en sí
mismo. Además es innecesario: los fallos a nivel de campo son sistemáticos y aparecen en el
primer puñado de scrapes, que es para lo que está la revisión manual de la fase 1. El informe
automático cubre tasas de desenlace, latencia, y si llegó a existir un archive item y una
captura.

## Por qué no un 10% uniforme

A ~100 scrapes/día repartidos entre cinco plataformas:

| Configuración | Exposición | Por plataforma | Tiempo hasta una respuesta de ±3pp |
|---|---|---|---|
| 10% en las cinco | ~10/día | ~2/día | ~100 días |
| 100% de **una** plataforma | ~20/día | ~20/día | ~10 días |

Estimar una tasa de éxito del ~95% con un margen de ±3 puntos porcentuales necesita del orden
de 200 observaciones. Las dos filas conllevan prácticamente el mismo riesgo y se diferencian en
un factor de diez en lo que enseñan.

El reparto 90/10 es además el instinto equivocado aquí: la asignación equilibrada importa
cuando tienes que medir los dos brazos a la vez, pero **la línea base de Hypatia ya está en la
base de datos** tras años de producción. Cada scrape enviado a Hypatia durante el canario no
nos enseña nada nuevo, así que el porcentaje lo debe fijar cuánta rotura podemos absorber, no
la estadística.

## Fases

### Fase 0 — Cerrar el agujero (bloqueante)
`ScrapeTimeoutJob`, armado al despachar al orquestador. No empieza nada más hasta que los
scrapes atascados sean visibles.

### Fase 1 — Humo, 2-3 días, 10% en todas las plataformas
Aquí el 10% sí es lo correcto, porque esto no es estadística: es **leerse los ~30 scrapes a
mano** y comparar cada elemento archivado con lo que produce Hypatia para la misma URL. Los
fallos sistemáticos aparecen en el primero, no en el doscientos. El sí/no es cualitativo.

### Fase 2 — Una plataforma al 100%, ~10 días
Empezar por la plataforma de más volumen: responde antes, y es donde más cuesta una regresión,
así que es donde antes queremos saberlo. ~200 scrapes dan la tasa de esa plataforma con ±3pp y
una decisión de verdad.

### Fase 3 — El resto, ~2 semanas
Una vez que una plataforma ha validado la maquinaria compartida (callback, auth, transferencia
de medios, el armazón del mapeo), las demás sólo aportan su propio mapeo. Pueden ir juntas.

### Fase 4 — Cutover
`ZENODOTUS_CALLBACK_REQUIRED=true`, Hypatia retirada, y la columna `backend` se mantiene para
el histórico.

Aproximadamente un mes de principio a fin. Estrictamente secuencial plataforma por plataforma
serían dos meses y medio, y no compensa.

## Implementación

En la rama `dfernandez/mv-6-orchestrator-cutover`.

**1 — Migración.** `scrapes.backend` (string, nullable; nulo = anterior al canario, o sea
Hypatia) y `scrapes.dispatched_at`. Un string normal con un enum de Rails en vez de un enum de
PG como `scrape_type`: los valores todavía pueden cambiar, y alterar un enum de PG in situ es
doloroso. Índices sobre `backend` y sobre `(fulfilled, error, dispatched_at)` para la consulta
de scrapes atascados.

`dispatched_at` es cuándo entregamos el scrape por última vez, que no es `created_at` — ese
incluye el tiempo en cola. Lo necesitan tanto el temporizador como la métrica de latencia.

**2 — Enrutado.** `Scrape#orchestrator_enabled?` se convierte en `assign_backend!` +
`choose_backend`, que consultan `USE_ORCHESTRATOR`, la lista de plataformas permitidas y
`Flipper.enabled?(:"orchestrator_canary_#{scrape_type}", self)`, con `rescue` a `hypatia`.
`backend` se escribe una vez; `dispatched_at`, en cada intento.

**3 — `ScrapeTimeoutJob`.** Armado al final de un despacho exitoso al orquestador. Al saltar:
no hace nada si el scrape está cumplido o ya errado, no hace nada si se redespachó desde
entonces (comparando `dispatched_at`), y si no, `mark_error` y aviso a Honeybadger.

**4 — Auth del callback por scrape.** El `before_action` se convierte en una comprobación
dentro de la acción, después de encontrar el scrape, más la anulación con
`ZENODOTUS_CALLBACK_REQUIRED`. Revisa el comportamiento introducido antes en esta misma rama.

**5 — Informe y visibilidad.** `rails canary:report[días]` — por backend × plataforma: totales,
cumplidos/error/eliminados/atascados, latencia p50 y p90, y la proporción de scrapes cumplidos
con archive item y con captura. Además, `backend` visible en la lista de scrapes del admin y en
el contexto de Honeybadger, y una acción "Rescue onto Hypatia" (la red manual de D5) que sella
un `scrapes.rescued_at` nuevo — el informe los cuenta, y ese recuento es la tasa de fallo
honesta. El botón existente de "resubmit all" ahora mantiene cada scrape en su propio backend,
así que su comentario, que decía que reenvía a Hypatia, se ha corregido en vez de dejarlo
convertirse en mentira.

Nótese que el proyecto tiene Blazer instalado, así que en cuanto exista la columna la misma
comparación se puede guardar como panel SQL para el equipo; la tarea de rake es la versión
autocontenida que viaja con el código.

**6 — Este documento.**

### Tests
Enrutado: estable entre reintentos; respeta la llave maestra, la lista de plataformas y el
porcentaje de Flipper; cae a Hypatia cuando Flipper lanza una excepción. Temporizador: no hace
nada si está cumplido, no hace nada si se redespachó, y marca error en el resto de casos. Auth
del callback: scrape de Hypatia sin bearer aceptado; scrape del orquestador rechazado sin él y
aceptado con él; `ZENODOTUS_CALLBACK_REQUIRED` forzándolo para ambos. Tarea de informe: humo.

## Runbook

```bash
# Una vez, antes de nada: registrar los cinco dials. Flipper avisa cada vez que le preguntan
# por un feature que no ha visto nunca, y en el camino del scraping eso es una línea de log
# por scrape.
rails canary:setup
```

```ruby
# Fase 1 — 10% en todas
%w[twitter instagram facebook tiktok youtube].each do |p|
  Flipper.enable_percentage_of_actors(:"orchestrator_canary_#{p}", 10)
end

# Fase 2 — una plataforma, entera
Flipper.enable_percentage_of_actors(:orchestrator_canary_twitter, 100)
%w[instagram facebook tiktok youtube].each do |p|
  Flipper.disable(:"orchestrator_canary_#{p}")
end

# Parar todo, de inmediato, sin desplegar
%w[twitter instagram facebook tiktok youtube].each do |p|
  Flipper.disable(:"orchestrator_canary_#{p}")
end
```

Antes de la fase 1, y en este orden: poner `ZENODOTUS_CALLBACK_TOKEN` **primero** en el Secret
del orquestador, y después en Zenodotus (ver `STAGING.md`) — al revés, todos los callbacks del
orquestador dan 401 hasta que aterriza la segunda mitad. `USE_ORCHESTRATOR=true` y
`MITROPOULOS_URL` tienen que estar puestos los dos, o todos los dials son inertes.

Los números se leen con `rails canary:report[7]`.

## Probarlo a mano

Todo lo de abajo corre contra un checkout local, sin orquestador y sin Antena. Levanta primero
los contenedores (`docs/TESTING.md`) y luego `rails db:setup`.

### ¿A dónde va un scrape?

```ruby
# rails console, con USE_ORCHESTRATOR=true y MITROPOULOS_URL apuntando a cualquier cosa
def goes_to(type)
  s = Scrape.create!(url: "https://example.com/#{SecureRandom.hex(4)}", scrape_type: type)
  s.assign_backend!
  s.backend
end

goes_to("instagram")                                                   # => "hypatia" (dial cerrado)
Flipper.enable_percentage_of_actors(:orchestrator_canary_instagram, 100)
goes_to("instagram")                                                   # => "orchestrator"
goes_to("twitter")                                                     # => "hypatia" (tiene su propio dial)

# Al 30%, aproximadamente tres de cada diez:
Flipper.enable_percentage_of_actors(:orchestrator_canary_instagram, 30)
40.times.map { goes_to("instagram") }.tally                            # => {"hypatia"=>31, "orchestrator"=>9}

# Y un scrape no se mueve nunca, por mucho que el dial se mueva debajo:
s = Scrape.create!(url: "https://example.com/stable", scrape_type: :instagram)
Flipper.enable_percentage_of_actors(:orchestrator_canary_instagram, 100)
s.assign_backend!                                    # "orchestrator"
Flipper.disable(:orchestrator_canary_instagram)
s.assign_backend!                                    # sigue siendo "orchestrator"
```

### ¿El callback rechaza de verdad?

Arranca el servidor con `ZENODOTUS_CALLBACK_TOKEN=secreto-de-prueba`, crea un scrape en cada
backend, y haz POST a `/archive/scrape_result_callback` (ojo: sin prefijo `/media_vault` —
`scope module:` no añade segmento de ruta).

```bash
CB=http://localhost:3000/archive/scrape_result_callback
hit() { curl -s -o /dev/null -w "%{http_code}\n" -X POST "$CB" \
  -H 'Content-Type: application/json' "${@:2}" \
  -d "{\"scrape_id\":\"$1\",\"scrape_result\":[{\"status\":\"removed\"}]}"; }

hit $HYPATIA_ID                                                    # 200 — vía legacy, no le pedimos bearer
hit $ORCH_ID                                                       # 401
hit $ORCH_ID -H 'Authorization: Bearer nope'                       # 401
hit $ORCH_ID -H 'Authorization: secreto-de-prueba'                 # 401 — el esquema es obligatorio
hit $ORCH_ID -H 'Authorization: Bearer secreto-de-prueba'          # 200
hit 00000000-0000-0000-0000-000000000000 -H 'Authorization: Bearer secreto-de-prueba'  # 404
```

### ¿Salta el temporizador?

```ruby
s = Scrape.create!(url: "https://example.com/lost", scrape_type: :instagram)
s.update_columns(backend: "orchestrator", dispatched_at: 31.minutes.ago)
s.fulfilled?, s.error?          # => false, false — hoy esto es invisible

ScrapeTimeoutJob.perform_now(s)
s.reload.error?                 # => true

# Deja en paz un scrape cuyo callback llegó, y uno redespachado desde entonces:
s2.update_columns(backend: "orchestrator", dispatched_at: 31.minutes.ago, fulfilled: true)
ScrapeTimeoutJob.perform_now(s2); s2.reload.error?   # => false
s3.update_columns(backend: "orchestrator", dispatched_at: 1.minute.ago)
ScrapeTimeoutJob.perform_now(s3); s3.reload.error?   # => false
```

### ¿Qué pinta tiene el informe?

```
backend      platform    total     ok  error  removed  stuck     p50     p90   item   shot
------------------------------------------------------------------------------------------
hypatia      instagram      20   100%     0%       0%     0%     60s     60s     0%     0%
orchestrator instagram      10    80%    20%       0%     0%    100s    100s     0%     0%
orchestrator twitter         1     0%     0%       0%   100%       -       -      -      -

Manually rescued onto Hypatia: 2
```
