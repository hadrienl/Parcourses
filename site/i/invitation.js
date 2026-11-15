// Page /i/ (#87, lot 87.7) : lit le jeton dans le fragment et prépare « Ouvrir dans l'app » (schéma parcourses://).
// Aucun appel réseau ; le jeton ne quitte la page que vers l'app. Même règle que SharingDecisions.parseInvitationLink :
// 43 caractères base64url.
"use strict";
(function () {
  var token = window.location.hash.replace(/^#/, "");
  var valid = /^[A-Za-z0-9_-]{43}$/.test(token);
  var open = document.getElementById("open");
  if (valid) {
    open.href = "parcourses://invitation#" + token;
    open.hidden = false;
  } else {
    document.getElementById("invitation").hidden = true;
    document.getElementById("broken").hidden = false;
  }
})();
