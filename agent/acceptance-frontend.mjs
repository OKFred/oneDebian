// Owned, temporary Node frontend for the explicit browser acceptance check.
import http from 'node:http';
const page='<!doctype html><meta charset="utf-8"><title>oneDebian acceptance</title><h1>oneDebian acceptance</h1>'+
'<form><label>Name <input name="name" aria-label="Name"></label><button type="submit">Submit</button></form><p id="result" role="status">Waiting</p>'+
'<script>document.querySelector("form").onsubmit=e=>{e.preventDefault();document.querySelector("#result").textContent="Hello "+document.querySelector("input").value;};</script>';
const server=http.createServer((req,res)=>{
  res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'});
  res.end(page);
});
server.listen(0,'127.0.0.1',()=>console.log(server.address().port));
