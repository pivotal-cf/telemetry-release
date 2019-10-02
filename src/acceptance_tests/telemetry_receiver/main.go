package main

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/pkg/errors"
)

const (
	PortEnvVar         = "PORT"
	ApiKeysEnvVar      = "VALID_API_KEYS"
	MessageLimitEnvVar = "MESSAGE_LIMIT"

	RequiredEnvVarNotSetErrorFormat = "%s environment variable not set"
	FailedUnmarshalErrorFormat      = "%s failed to json unmarshal"
	InvalidMessageLimitError        = "message limit configuration invalid"
)

var (
	userApiKeys map[string][]string
	messages    map[string][]map[string]interface{}
	batchMessages map[string][]map[string]interface{}

	messageLimit int
)

func main() {
	if err := validateEnvConfigured(); err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}

	bindAddr := fmt.Sprintf(":%s", os.Getenv(PortEnvVar))

	messages = map[string][]map[string]interface{}{}
	batchMessages = map[string][]map[string]interface{}{}
	http.HandleFunc("/collections/batch", postMessageHandler(readTarBatch, batchMessages))
	http.HandleFunc("/components", postMessageHandler(readJSONBatch, messages))
	http.HandleFunc("/received_messages", readMessagesForUser(messages))
	http.HandleFunc("/received_batch_messages", readMessagesForUser(batchMessages))
	http.HandleFunc("/clear_messages", clearMessages)

	err := http.ListenAndServe(bindAddr, nil)
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
}

func postMessageHandler(
	messageReader func(contents []byte) ([]map[string]interface{}, error),
	messagesToUpdate map[string][]map[string]interface{}) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, authed := authenticated(r.Header, userApiKeys)
		if !authed {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		reqBody, err := ioutil.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		defer r.Body.Close()
		recMessages, err := messageReader(reqBody)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}

		updateMessages(userID, messagesToUpdate, recMessages)

		w.WriteHeader(http.StatusCreated)
	}
}

func updateMessages(userID string, messagesToUpdate map[string][]map[string]interface{}, receivedMessages []map[string]interface{}) {
	messagesToRemove := len(receivedMessages) + len(messagesToUpdate[userID]) - messageLimit
	currMessages := messagesToUpdate[userID]
	if messagesToRemove > 0 {
		currMessages = currMessages[messagesToRemove:]
	}
	messagesToUpdate[userID] = append(currMessages, receivedMessages...)
}

func readMessagesForUser(receivedMessages map[string][]map[string]interface{}) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, authed := authenticated(r.Header, userApiKeys)
		if !authed {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		userMessages, ok := receivedMessages[userID]
		if ok {
			msgBytes, err := json.Marshal(&userMessages)
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.Write(msgBytes)
		} else {
			w.Write([]byte("[]"))
		}
	}
}

func clearMessages(w http.ResponseWriter, r *http.Request) {
	userID, authed := authenticated(r.Header, userApiKeys)
	if !authed {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	delete(messages, userID)
	delete(batchMessages, userID)
}

func authenticated(h http.Header, validUserApiKeys map[string][]string) (string, bool) {
	authHeaderToken := tokenFromHeader(h)
	for userID, keys := range validUserApiKeys {
		for _, validUserKey := range keys {
			if authHeaderToken == validUserKey {
				return userID, true
			}
		}
	}
	return "", false
}

func tokenFromHeader(h http.Header) string {
	authHeader := h.Get("Authorization")
	authHeaderParts := strings.Split(authHeader, " ")
	if len(authHeaderParts) != 2 || (authHeaderParts[0] != "Bearer") {
		return ""
	}
	return authHeaderParts[1]
}

func validateEnvConfigured() error {
	requiredEnvVars := []string{
		PortEnvVar,
		ApiKeysEnvVar,
		MessageLimitEnvVar,
	}

	for _, e := range requiredEnvVars {
		value := os.Getenv(e)
		if value == "" {
			return errors.Errorf(RequiredEnvVarNotSetErrorFormat, e)
		}
	}

	err := json.Unmarshal([]byte(os.Getenv(ApiKeysEnvVar)), &userApiKeys)
	if err != nil {
		return errors.Wrapf(err, FailedUnmarshalErrorFormat, ApiKeysEnvVar)
	}

	messageLimit, err = strconv.Atoi(os.Getenv(MessageLimitEnvVar))
	if err != nil {
		return errors.Wrap(err, InvalidMessageLimitError)
	}

	return nil
}

func readJSONBatch(batchContents []byte) ([]map[string]interface{}, error) {
	decoder := json.NewDecoder(bytes.NewReader(batchContents))
	var jsonObjSlice []map[string]interface{}
	for {
		var jsonObj map[string]interface{}

		if err := decoder.Decode(&jsonObj); err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}
		jsonObjSlice = append(jsonObjSlice, jsonObj)

	}
	return jsonObjSlice, nil
}

func readTarBatch(contents []byte) ([]map[string]interface{}, error) {
	tarReader := tar.NewReader(bytes.NewReader(contents))

	var messagesInTar []map[string]interface{}
	for {
		hdr, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, errors.Wrap(err, "failed to read header")
		}

		if hdr.Typeflag == tar.TypeReg {
			if strings.HasSuffix(hdr.Name, "metadata") {
				metadata := struct {
					CollectedAt  string
					FoundationId string
				}{}

				err := json.NewDecoder(tarReader).Decode(&metadata)
				if err != nil {
					return nil, errors.Wrapf(err, "failed to read file contents %s", hdr.Name)
				}

				messagesInTar = append(messagesInTar, map[string]interface{}{
					"FoundationId": metadata.FoundationId,
					"CollectedAt":  metadata.CollectedAt,
					"Dataset":      filepath.Dir(hdr.Name),
				})
			}
		}
	}

	return messagesInTar, nil
}
