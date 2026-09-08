
MonCon = function () {

    this.conOk = function () {
        window.setTimeout(MonCon.ping, 5000);
    }

    this.ping = function () {
        var self = this;
        var loaded = false;
        var failCount = 0;
        var formats = ['gif', 'svg','png','jpg','jpeg','bmp','webp'];
        formats.forEach(function (fmt) {
            var imgPath = '/luci-static/resources/icons/loading.' + fmt + '?' + Math.random();
            var img = document.createElement('img');
            img.onload = function () {
                if (!loaded) {
                    loaded = true;
                    self.conOk();
                }
            };
            img.onerror = function () {
                failCount++;
                if (failCount === formats.length && !loaded) {
                    self.conErr();
                }
            };
            img.src = imgPath;
        });
    }

    this.conErr = function () {
        alert('Device unreachable!');
        window.location.reload(true);
    }

}
MonCon.ping = function () {
    (new MonCon()).ping();
}
