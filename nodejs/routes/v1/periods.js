
var get_periods_from_channel = function(req, res) {
    var q = 'SELECT log_event.probe_id, ';
    q += 'log_event.daemon_session_id, ';
    q += 'probes.distance, ';
    q += 'probes.name, ';
    q += 'probes.switch, ';
    q += 'probes.shortloc, ';
    q += 'stream_session.multicast_dst, ';
    q += 'stream_session.port_dst, ';
    q += 'sum(delta_skips) as skips, ';
    q += 'sum(delta_discon) as drops, ';
    q += 'count(log_event.multicast_dst) as records, ';
    q += 'UNIX_TIMESTAMP(min(record_time)) * 1000 as time_min, ';
    q += 'UNIX_TIMESTAMP(max(record_time)) * 1000 as time_max, ';
    q += 'TIMESTAMPDIFF(SECOND, min(record_time), max(record_time)) * 1000 as period ';
    q += 'FROM log_event, probes, stream_session ';
    q += 'WHERE log_event.probe_id = probes.id ';
    q += 'AND log_event.stream_session_id = stream_session_id ';
    q += 'AND stream_session.multicast_dst = ? ';
    q += 'AND stream_session.port_dst = ? ';
    q += 'AND UNIX_TIMESTAMP(record_time) * 1000 BETWEEN ? AND ? ';
    q += 'GROUP BY daemon_session_id, probe_id ';
    q += 'ORDER BY probes.distance, probe_id, time_min';
    var params = [req.params.channel, req.params.port, req.query.time_from, req.query.time_to];
    connection.query(q, params, function(err, result) {
        if (err) {
        	res.statusCode = 500;
        	logger.error('Error retrieving periods: '+ err);
            res.send('Error retrieving periods: '+ err);
            //console.log(err.fatal);
            return;
        }
	    res.header('Cache-Control', 'no-cache, no-store');
        res.header('Expires', '-1');
        res.header('Pragma', 'no-cache');
        res.send({periods: result});
    });
}


exports.init = function(app, url) {
    app.get(url + '/:channel/:port', function(req, res) { get_periods_from_channel(req, res); });
}