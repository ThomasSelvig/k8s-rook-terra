echo "Port forwarding to Grafana on http://localhost:3002"
echo "Username: admin"
echo "Password: admin"
kubectl -n monitoring port-forward services/grafana 3002:3000
