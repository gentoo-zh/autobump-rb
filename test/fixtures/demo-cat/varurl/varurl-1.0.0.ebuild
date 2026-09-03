# Copyright 2026 Gentoo Authors
EAPI=8
MY_PN="upstream-name"
DESCRIPTION="vendor URL built from a variable the engine does not expand"
SRC_URI="
	https://example.invalid/${P}.tar.gz
	https://github.com/gentoo-zh-drafts/varurl/releases/download/v${PV}/${MY_PN}-${PV}-vendor.tar.xz
"
KEYWORDS="~amd64"
