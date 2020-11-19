
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

var get_channels_by_probe = function(req, res) {
    var q = 'SELECT log_event.probe_id, stream_session.multicast_dst, stream_session.port_dst, ';
    q += 'sum(delta_skips) as skips, sum(delta_discon) as drops, sum(delta_packets) as packets, sum(delta_payload_bytes) as payload_bytes, ';
    q += 'count(log_event.multicast_dst) as records ';
    q += 'FROM log_event, stream_session WHERE log_event.stream_session_id = stream_session.id ';
    q += 'AND log_event.probe_id = ? ';
    q += 'AND UNIX_TIMESTAMP(record_time) * 1000 BETWEEN ? AND ? ';
    q += 'GROUP BY multicast_dst ORDER BY multicast_dst ';
    connection.query(q, [req.params.probe_id, req.query.time_from, req.query.time_to], function(err, result) {
        if (err) {
            //console.log(err.fatal);
        	res.statusCode = 500;
        	logger.error('Error retrieving channels from probe: '+ err);
            res.send('Error retrieving channels from probe: '+ err);
            return;
        }
	    res.header('Cache-Control', 'no-cache, no-store');
        res.header('Expires', '-1');
        res.header('Pragma', 'no-cache');
        res.send({channels: result});
    });}


exports.init = function(app, url) {
    app.get(url, function(req, res) { get_channels(req, res); });
    app.get(url + '/probe/:probe_id', function(req, res) { get_channels_by_probe(req, res); });
}