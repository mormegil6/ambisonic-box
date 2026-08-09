import axios from "axios";
import React from "react";
import xml2js from "xml2js";
import moment from "moment";
import Table from "@material-ui/core/Table";
import TableBody from "@material-ui/core/TableBody";
import TableCell from "@material-ui/core/TableCell";
import TableRow from "@material-ui/core/TableRow";

import DashPlayer from "./DashPlayer";

const STAT_URL = "/stat";
const NGINX_INFO_URL = "/nginxInfo";

const SERVER_INFO_FIELDS = {
  bandwidthIn: "bw_in",
  bytesIn: "bytes_in",
  bwOut: "bw_out",
  totalBytesOut: "bytes_out",
  uptime: "uptime",
  nclients: "nclients",
};

const SERVER_INFO_FIELD_NAMES = {
  bandwidthIn: "Bandwidth In",
  bytesIn: "Total Bytes In",
  bwOut: "Bandwidth Out",
  bytesOut: "Total Bytes Out",
  uptime: "Server Uptime",
  nclients: "Num Clients",
};

const DEFAULT_STAT_REFRESH_PERIOD = 4; // seconds

export default class Webtools extends React.Component {
  static loadStat(self) {
    axios
      .get(STAT_URL, {
        "Content-Type": "application/xml; charset=utf-8",
      })
      .then((response) => {
        xml2js.parseString(response.data, (err, result) => {
          const serverInfo = Webtools.extractServerInfo(result);
          const liveInfo = result.rtmp.server[0].application[0].live[0];
          serverInfo.nclients = liveInfo.nclients;
          const stateUpdate = {
            serverInfo,
            statRetryTimer: self.state.statRetryTimer * 2,
          };
          if (liveInfo.stream) {
            const streamNames = liveInfo.stream.map((stream) => stream.name[0]);
            stateUpdate.streamNames = streamNames;
            if (self.state.selectedStream === null) {
              [stateUpdate.selectedStream] = streamNames;
            }
            stateUpdate.statRetryTimer = DEFAULT_STAT_REFRESH_PERIOD;
            stateUpdate.directStream = false;
            Webtools.applyStatUpdate(self, stateUpdate);
            return;
          }
          // No RTMP publisher does not mean no stream: the SRT direct path
          // (gateway -> tcp listener -> DASH) never appears in nginx-rtmp's
          // stat page, but it writes the exact manifest this page plays. A
          // manifest the server modified within the last few seconds IS a
          // live stream; comparing the server's own Date and Last-Modified
          // headers keeps client clock skew out of the decision.
          Webtools.probeDirectStream(self, stateUpdate);
        });
      })
      .catch(() => {
        setTimeout(() => {
          Webtools.loadStat(self);
        }, self.state.statRetryTimer * 1000);
      });
  }

  static probeDirectStream(self, stateUpdate) {
    const { dashName } = self.state;
    if (!dashName) {
      Webtools.applyStatUpdate(self, stateUpdate);
      return;
    }
    // HEAD, not GET: the freshness verdict is entirely in the headers, so
    // there is no reason to pull the manifest body every poll.
    axios
      .head(`/dash/${dashName}.mpd`, {
        headers: { "Cache-Control": "no-cache" },
      })
      .then((res) => {
        const modified = new Date(res.headers["last-modified"]).getTime();
        const served = new Date(res.headers.date).getTime();
        if (modified && served && served - modified < 20000) {
          stateUpdate.streamNames = [dashName];
          stateUpdate.directStream = true;
          if (self.state.selectedStream === null) {
            stateUpdate.selectedStream = dashName;
          }
          stateUpdate.statRetryTimer = DEFAULT_STAT_REFRESH_PERIOD;
        }
        Webtools.applyStatUpdate(self, stateUpdate);
      })
      .catch(() => {
        Webtools.applyStatUpdate(self, stateUpdate);
      });
  }

  static applyStatUpdate(self, stateUpdate) {
    self.setState(stateUpdate);
    setTimeout(() => {
      Webtools.loadStat(self);
    }, stateUpdate.statRetryTimer * 1000);
  }

  static extractServerInfo(statResponse) {
    const serverInfo = {};
    Object.keys(SERVER_INFO_FIELDS).forEach((key) => {
      const responseKey = SERVER_INFO_FIELDS[key];
      if (statResponse.rtmp[key]) {
        [serverInfo[key]] = statResponse.rtmp[responseKey];
      }
    });
    return serverInfo;
  }

  SERVER_INFO_TRANSFORM = {
    uptime: (uptime) => moment.duration(uptime, "seconds").humanize(),
    bwIn: this.BW_TRANSFORM_FN,
    bwOut: this.BW_TRANSFORM_FN,
    bytesIn: this.BYTES_TRANSFORM_FN,
    bytesOut: this.BYTES_TRANSFORM_FN,
  };

  constructor(props) {
    super(props);
    this.state = {
      ffmpegFlags: null,
      dashName: null,
      directStream: false,
      streamNames: null,
      selectedStream: null,
      serverInfo: null,
      statRetryTimer: 1,
    };
  }

  componentDidMount() {
    // Order matters: /nginxInfo carries the manifest name the direct-stream
    // probe needs, and the two used to race. When stat answered first on a
    // direct stream, dashName was still null, the probe bailed, and discovery
    // waited out a whole doubled retry - the 1-2 s of extra "Searching for
    // streams" the operator saw on 2026-08-09. Chain instead, and start the
    // stat loop even if /nginxInfo fails (RTMP discovery still works).
    this.loadEarshotInfo().finally(() => Webtools.loadStat(this));
  }

  BW_TRANSFORM_FN = (bwIn) =>
    `${parseFloat((bwIn / (1024 * 1024)).toPrecision(4))}Mb/s`;

  BYTES_TRANSFORM_FN = (bytesIn) => {
    if (bytesIn > 1024 * 1024 * 1024) {
      return `${parseFloat((bytesIn / (1024 * 1024 * 1024)).toPrecision(4))}GB`;
    }
    return `${parseFloat((bytesIn / (1024 * 1024)).toPrecision(4))}MB`;
  };

  loadEarshotInfo() {
    return axios.get(NGINX_INFO_URL).then((response) => {
      this.setState({
        ffmpegFlags: response.data.ffmpegFlags,
        // which manifest the direct (non-RTMP) path writes; feeds the
        // stat-less stream discovery in probeDirectStream
        dashName: response.data.dashName,
      });
    });
  }

  selectStream(streamName) {
    this.setState({
      selectedStream: streamName,
    });
  }

  renderNginxInfo() {
    const { ffmpegFlags } = this.state;
    return (
      <TableRow>
        <TableCell style={{ padding: "2px 15px 2px 0px" }}>
          FFmpeg Flags
        </TableCell>
        <TableCell style={{ fontSize: "10px" }}>
          {ffmpegFlags !== null ? ffmpegFlags : "Loading..."}
        </TableCell>
      </TableRow>
    );
  }

  renderServerInfo() {
    const { serverInfo, directStream } = this.state;
    const rows = Object.keys(serverInfo).map((key) => {
      let serverInfoValue = this.SERVER_INFO_TRANSFORM[key]
        ? this.SERVER_INFO_TRANSFORM[key](serverInfo[key])
        : serverInfo[key];
      // nclients counts RTMP connections, which a direct (SRT -> tcp
      // listener) stream has none of - a bare "0" beside a stream that is
      // plainly playing reads as a fault. Say which zero it is.
      if (key === "nclients" && directStream) {
        serverInfoValue = "0 (direct stream, no RTMP clients)";
      }

      return (
        <TableRow key={key}>
          <TableCell style={{ padding: "2px 15px 2px 0px" }}>
            {SERVER_INFO_FIELD_NAMES[key]}
          </TableCell>
          <TableCell>{serverInfoValue}</TableCell>
        </TableRow>
      );
    });

    return <>{rows}</>;
  }

  renderSearchingForStreams() {
    const { statRetryTimer } = this.state;
    return (
      <div className="SearchingOrLoadingStreamsContainer">
        <div className="SearchingOrLoadingStreamsText">
          Searching for streams...
          <br />
          (Retrying after {statRetryTimer} Seconds)
        </div>
      </div>
    );
  }

  renderStreamNames() {
    const { streamNames } = this.state;
    const self = this;
    let i = -1;
    return streamNames.map((streamName) => {
      i += 1;
      let classNames = "StreamName";
      if (self.state.selectedStream === streamName) {
        classNames += " Selected";
      }
      return (
        <div
          className={classNames}
          key={streamName}
          onClick={() => {
            self.selectStream(streamName);
          }}
          onKeyDown={() => {
            self.selectStream(streamName);
          }}
          role="button"
          tabIndex={i}
        >
          {streamName}
        </div>
      );
    });
  }

  render() {
    const { selectedStream, serverInfo, streamNames } = this.state;
    return (
      <div className="WebtoolsContainer">
        <div className="StreamSelectionSidebar">
          <img
            alt="Earshot Logo"
            src="/webtools/logo.png"
            style={{ width: "100%" }}
          />
          {streamNames && this.renderStreamNames()}
          <div className="ServerInfo">
            <Table>
              <TableBody>
                {serverInfo && this.renderServerInfo()}
                {this.renderNginxInfo()}
              </TableBody>
            </Table>
          </div>
        </div>
        {!streamNames && this.renderSearchingForStreams()}
        {selectedStream && (
          <div className="DashPlayerContainer">
            <DashPlayer
              streamName={selectedStream}
              streamUrl={`/dash/${selectedStream}.mpd`}
            />
          </div>
        )}
      </div>
    );
  }
}
