PORTNAME=	install-fbsd-desktop
DISTVERSION=	0.2.0
CATEGORIES=	sysutils

# Maintainer: Nicholas Bernstein
MAINTAINER=	install-fbsd-desktop@nicholasbernstein.com
COMMENT=	Interactive installer for FreeBSD desktop environments
WWW=		https://github.com/nicholasbernstein/install-fbsd-desktop

LICENSE=	BSD3CLAUSE
LICENSE_FILE=	${WRKSRC}/license.txt

# Interactive menus require cdialog (ComeOn Dialog). installx.sh will also
# pkg-install it on first interactive run if missing.
RUN_DEPENDS=	cdialog:devel/cdialog

NO_ARCH=	yes
NO_BUILD=	yes

OPTIONS_DEFINE=	DOCS
PORTDOCS=	ReadMe.md

# ---------------------------------------------------------------------------
# Source selection
#
# Default when this port lives inside the install-fbsd-desktop git checkout:
# copy files from the monorepo root (../../../). No network, no distinfo needed.
#
# For an official ports-tree build (or CI that only has the port directory),
# set FORCE_GITHUB=yes or build where ../../../installx.sh is absent — then
# USE_GITHUB fetches a tagged/commit snapshot. Run `make makesum` after changing
# GH_TAGNAME / DISTVERSION.
# ---------------------------------------------------------------------------
_LOCAL_SRC=	${.CURDIR}/../../..

.if exists(${_LOCAL_SRC}/installx.sh) && !defined(FORCE_GITHUB)
MASTER_SITES=	#
DISTFILES=	#
EXTRACT_ONLY=	#
NO_CHECKSUM=	yes
WRKSRC=		${WRKDIR}/${PORTNAME}-${DISTVERSION}

do-extract:
	@${MKDIR} ${WRKSRC}
	@${CP} ${_LOCAL_SRC}/installx.sh ${WRKSRC}/
	@${CP} ${_LOCAL_SRC}/test_installx.sh ${WRKSRC}/
	@${CP} ${_LOCAL_SRC}/shunit2 ${WRKSRC}/
	@${CP} ${_LOCAL_SRC}/license.txt ${WRKSRC}/
	@${CP} ${_LOCAL_SRC}/ReadMe.md ${WRKSRC}/
.else
USE_GITHUB=	yes
GH_ACCOUNT=	nicholasbernstein
GH_PROJECT=	install-fbsd-desktop
# Pin to a commit or release tag; update with DISTVERSION and `make makesum`
GH_TAGNAME=	d1e7ddc5e5780bf4b550f4cd3315a4ca9a4d4988
.endif

do-install:
	${INSTALL_SCRIPT} ${WRKSRC}/installx.sh \
		${STAGEDIR}${PREFIX}/sbin/installx
	${RLN} ${STAGEDIR}${PREFIX}/sbin/installx \
		${STAGEDIR}${PREFIX}/sbin/install-fbsd-desktop
	${MKDIR} ${STAGEDIR}${DATADIR}
	${INSTALL_SCRIPT} ${WRKSRC}/test_installx.sh ${STAGEDIR}${DATADIR}
	${INSTALL_DATA} ${WRKSRC}/shunit2 ${STAGEDIR}${DATADIR}

do-install-DOCS-on:
	${MKDIR} ${STAGEDIR}${DOCSDIR}
	${INSTALL_DATA} ${WRKSRC}/ReadMe.md ${STAGEDIR}${DOCSDIR}

.include <bsd.port.mk>
