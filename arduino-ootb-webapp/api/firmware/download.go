package firmware

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"time"
	"x8-ootb/utils"

	"github.com/inconshreveable/log15"
)

type FirmwareUpdateProgress struct {
	Percentage         float64 `json:"percentage"`
	Md5Error           error   `json:"md5Error"`
	UntarError         error   `json:"untarError"`
	Status             string  `json:"status"`
	OfflineUpdateError string  `json:"offlineUpdateError"`
}
type WriteCounter struct {
	Progress   uint64
	Percentage *float64
	Total      uint64
}

func (wc *WriteCounter) Write(p []byte) (int, error) {
	n := len(p)
	wc.Progress += uint64(n)
	*wc.Percentage = (float64(wc.Progress) / float64(wc.Total)) * 100
	// fmt.Println("Download -", *wc.Percentage)

	return n, nil
}

func DownloadVersion(url string, progress *FirmwareUpdateProgress, md5 string) {
	err := DownloadFile("/var/sota/update-latest.tar.gz", url, &progress.Percentage)
	if err != nil {
		log15.Error("Download update error", "url", url, "err", err)
		return
	}

	progress.Status = "md5"
	out, err := utils.ExecSh("md5sum /var/sota/update-latest.tar.gz")
	if err != nil {
		log15.Error("Checking md5 error", "err", err)
		return
	}

	trimmedOut := out[0:32]
	if trimmedOut != md5 {
		log15.Error("md5 mismatch", "err", err, "out", out, "trimmedOut", trimmedOut, "md5", md5)
		progress.Md5Error = err
		return
	}

	progress.Status = "tar"
	_, err = utils.ExecSh("tar xzf /var/sota/update-latest.tar.gz -C /var/sota/")
	if err != nil {
		log15.Error("Untar file error", "err", err)
		progress.UntarError = err
		return
	}

	progress.Status = "dbus"
	dbusOut, err := utils.ExecSh("gdbus call --system --dest org.freedesktop.systemd1 --object-path /org/freedesktop/systemd1 --method org.freedesktop.systemd1.Manager.StartUnit \"offline-update.service\" \"fail\"")
	if err != nil {
		log15.Error("Sending data via DBus error", "err", err, "dbusOut", dbusOut)
		return
	}

	time.Sleep(1 * time.Second)

	ticker := time.NewTicker(200 * time.Millisecond)
	quit := make(chan struct{})
	go func() {
		for {
			select {
			case <-ticker.C:
				dbusOut, err := utils.ExecSh("gdbus introspect --system --dest org.freedesktop.systemd1 --object-path /org/freedesktop/systemd1/unit/offline_2dupdate_2eservice --only-properties | grep -i Active")
				if err != nil {
					log15.Error("Fetching firmware update status via DBus error", "err", err, "dbusOut", dbusOut)
					ticker.Stop()
					return
				}
				var re = regexp.MustCompile(`(?m)ActiveState = '([a-z]+)';`)

				reRes := re.FindAllStringSubmatch(dbusOut, -1)
				if len(reRes) == 0 || len(reRes[0]) == 0 {
					log15.Error("Invalid output from offline_2dupdate_2eservice", "dbusOut", dbusOut)
					ticker.Stop()
					return
				}

				switch reRes[0][1] {
				case "inactive":
					progress.Status = "Completed"
					ticker.Stop()
					return
				case "failed":
					progress.Status = "Completed"
					progress.OfflineUpdateError = "Error"
					ticker.Stop()
					return
				}

			case <-quit:
				ticker.Stop()
				return
			}
		}
	}()
}

func DownloadFile(filepath string, url string, percentage *float64) error {
	out, err := os.Create(filepath + ".tmp")
	if err != nil {
		return err
	}

	resp, err := http.Get(url)
	if err != nil {
		out.Close()
		return err
	}
	defer resp.Body.Close()

	counter := &WriteCounter{
		Percentage: percentage,
		Total:      uint64(resp.ContentLength),
	}
	if _, err = io.Copy(out, io.TeeReader(resp.Body, counter)); err != nil {
		out.Close()
		return err
	}

	fmt.Print("\n")

	out.Close()

	if err = os.Rename(filepath+".tmp", filepath); err != nil {
		return err
	}
	return nil
}
