package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os"
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
	userApiKeys  map[string][]string
	messages     map[string][]map[string]interface{}
	messageLimit int
)

func main() {
	if err := validateEnvConfigured(); err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}

	bindAddr := fmt.Sprintf(":%s", os.Getenv(PortEnvVar))

	messages = map[string][]map[string]interface{}{}
	http.HandleFunc("/components", components)
	http.HandleFunc("/received_messages", receivedMessages)
	http.HandleFunc("/clear_messages", clearMessages)

	err := http.ListenAndServe(bindAddr, nil)
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}
}

func components(w http.ResponseWriter, r *http.Request) {
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
	recMessages, err := readJSONBatch(reqBody)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	updateMessages(userID, recMessages)

	w.WriteHeader(http.StatusCreated)
}

func receivedMessages(w http.ResponseWriter, r *http.Request) {
	userID, authed := authenticated(r.Header, userApiKeys)
	if !authed {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	userMessages, ok := messages[userID]
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

func clearMessages(w http.ResponseWriter, r *http.Request) {
	userID, authed := authenticated(r.Header, userApiKeys)
	if !authed {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	delete(messages, userID)
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

func updateMessages(userID string, receivedMessages []map[string]interface{}) {
	messagesToRemove := len(receivedMessages) + len(messages[userID]) - messageLimit
	currMessages := messages[userID]
	if messagesToRemove > 0 {
		currMessages = currMessages[messagesToRemove:]
	}
	messages[userID] = append(currMessages, receivedMessages...)
}
