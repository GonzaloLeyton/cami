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

1. Abre Cami en el iPhone y déjala en primer plano. La pantalla no se apaga sola.
2. Con el cable conectado:

   ```bash
   ./linux/cami.sh
   ```

   Por Wi-Fi: `./linux/cami.sh <IP del iPhone>`.
3. En Zoom, Meet, OBS u otra app, elige la cámara **iPhone Cam**.

Elige la cámara del iPhone antes de abrir la app de videollamada. Si la nueva cámara tiene otro modo máximo, el formato cambia, y eso no es posible mientras una app está leyendo la cámara virtual.

Linux decodifica en la GPU: 4K60 HEVC con baja latencia no cabe en un solo núcleo de CPU. Probado a 61.8 fps en un Ryzen 5800X con una RTX 3060.
