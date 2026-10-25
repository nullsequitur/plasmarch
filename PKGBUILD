# Maintainer: Lampros <https://github.com/lampros>

pkgname=plasmarch
pkgver=0.2.0
pkgrel=1
pkgdesc="Layered, state-aware installer and manager for secondary KDE Plasma users on Arch Linux"
arch=('any')
url="https://github.com/lampros/PlasmArch"
license=('MIT')
depends=('bash' 'sudo' 'pacman')
optdepends=('whiptail: dialog-based interactive TUI checklist')
source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
  cd "$srcdir"
  if [[ -d "PlasmArch-$pkgver" ]]; then
    cd "PlasmArch-$pkgver"
  elif [[ -d "$pkgname-$pkgver" ]]; then
    cd "$pkgname-$pkgver"
  fi
  make DESTDIR="$pkgdir" PREFIX=/usr install
}
