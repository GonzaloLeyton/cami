# Cami: iPhone como webcam en Linux

La app del iPhone (`ios/Cami`) usa siempre el mejor modo de la cámara: la mayor resolución 16:9 que llegue a 60 fps (4K60 en un iPhone 16 Plus). La codifica en HEVC a unos 50 Mbps y la sirve por el puerto 5000.
El script de Linux (`linux/cami.sh`) la recibe por USB o Wi-Fi y la escribe en la cámara virtual "iPhone Cam" (v4l2loopback).

## 1. Instalar la app en el iPhone (sin Mac)

GitHub Actions compila `Cami.ipa` sin firmar en cada push a `main` (ver `.github/workflows/ios.yml`).

1. Descarga la última compilación: `gh run download -R GonzaloLeyton/cami -n Cami`
2. Abre [iloader](https://github.com/nab138/iloader), entra con tu Apple ID (sirve el gratuito) y con el iPhone conectado por cable usa **Import IPA** con `Cami.ipa`.
3. En el iPhone: Ajustes → Privacidad y seguridad → **Modo desarrollador** activado.
   La primera vez: Ajustes → General → VPN y gestión de dispositivos → confiar en tu cuenta.

Con un Apple ID gratuito la app caduca a los 7 días: vuelve a instalar el mismo `Cami.ipa` con iloader.

## 2. Usarla en Linux

Una sola vez, activa el servicio que arranca el receptor al iniciar sesión:

```bash
systemctl --user enable --now ~/Documents/cami/linux/cami.service
```

Desde ahí:

1. Conecta el iPhone por cable, abre Cami y déjala en primer plano. La pantalla no se apaga sola.
2. En Zoom, Meet, OBS u otra app, elige la cámara **iPhone Cam**.

Logs: `journalctl --user -u cami -f`. Desactivarlo: `systemctl --user disable --now cami`.
Por Wi-Fi, sin el servicio: `./linux/cami.sh <IP del iPhone>`.

Elige la cámara del iPhone antes de abrir la app de videollamada. Si la nueva cámara tiene otro modo máximo, el formato cambia, y eso no es posible mientras una app está leyendo la cámara virtual.

Linux decodifica en la GPU: 4K60 HEVC con baja latencia no cabe en un solo núcleo de CPU. Probado con un iPhone 16 Plus por USB: 3840×2160 a 60 fps y ~50 Mbps, en un Ryzen 5800X con una RTX 3060.
