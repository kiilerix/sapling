from __future__ import absolute_import

import pkgutil


# Indicate that hgext.native is a namespace package, and other python path
# directories may still be searched for hgext.native libraries.
__path__ = pkgutil.extend_path(__path__, __name__)
