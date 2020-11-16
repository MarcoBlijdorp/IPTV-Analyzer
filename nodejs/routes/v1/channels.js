
var get_channels = function(req, res) {
    var q = 'SELECT distinct multicast_dst, port_dst FROM stream_session ORDER BY INET_ATON(multicast_dst), port_dst';
    connection.query(q, function(err, result) {
        if (err) {
            //console.log(err.fatal);
        	res.statusCode = 500;
        	logger.error('Error retrieving channels: '+ err);
            res.send('Error retrieving channels: '+ err);
            return;
        }
	    res.header('Cache-Control', 'no-cache, no-store');
        res.header('Expires', '-1');
        res.header('Pragma', 'no-cache');
        res.send({channels: result});
    });
}


exports.init = function(app, url) {
    app.get(url, function(req, res) { get_channels(req, res); });
}